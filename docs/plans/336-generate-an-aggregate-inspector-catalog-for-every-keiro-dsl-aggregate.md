---
id: 336
slug: generate-an-aggregate-inspector-catalog-for-every-keiro-dsl-aggregate
title: "Generate an aggregate inspector catalog for every keiro-dsl aggregate"
kind: exec-plan
created_at: 2026-11-16T02:00:42Z
intention: intention_01m7jrjhcjezmsxe3kpfkm04ec
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-16T02:00:42Z
  reviews:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T03:58:21Z
      verdict: "comments"
      note: "Claims verified against the tree; Milestone 2 missed the service-package Cabal file, the eight exempt suites, and containers deps"
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-16T03:58:21Z
      mode: "update"
      note: "Made Milestone 2 corpus handling concrete and required docs/ADR to state display consequences"
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-16T18:05:54Z
      mode: "implement"
      note: "Implementing milestones 1-3"
---

# Generate an aggregate inspector catalog for every keiro-dsl aggregate

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A Keiro service can serve the keiro-ui inspection surface: an HTTP application, mounted
under `/keiro`, that lets an operator list aggregate types, open one aggregate by id, and
see its current folded state. To show an aggregate, the service must hand Keiro an
*aggregate inspector* for it: a small record naming the aggregate, its validated event
stream, its stream category, and how to render its state as JSON. Today `keiro-dsl`
generates every other piece the surface needs (the replay-audit target list and the
projection catalog) but not the inspectors. Every service therefore writes them by hand,
and nothing stops a service from forgetting one: a newly declared aggregate silently does
not appear in the console. The hand-written catalog in
`mori://tan/chapter-service-v2` (commit `43e2a93`, file
`chapter-service-v2-core/src/ChapterServiceV2/Domain/Inspection.hs`; artifact-level URI
pending) even carries an `uninspectedCategories` guard and a test whose only job is to
catch that omission.

After this plan, `keiro-dsl scaffold` emits one more generated module per service context,
`<generated prefix>.Inspection` (for example
`ChapterServiceV2.ChapterServiceV2.Generated.Inspection`), beside the existing
`.ReplayAudit` and `.ProjectionCatalog` modules. It exports a complete, already-validated
inspector catalog containing exactly one inspector per declared aggregate, plus the
replay-audit targets and projection catalog, so a host can mount the whole read-only
inspection surface from three generated values without writing any per-aggregate code.
Completeness holds by construction because the module is regenerated from the same
checked specification that produces the aggregates themselves.

The change ships in a published Keiro release so that other repositories can adopt it.
Two independent plans consume it: the Haskell Keiro project starter
(`mori://shinzui/seihou-modules/plans/15-mount-the-keiro-ui-inspection-surface-in-the-haskell-keiro-project-server-starter`)
and chapter-service-v2
(`mori://tan/chapter-service-v2/plans/1-adopt-the-generated-aggregate-inspector-catalog-in-chapter-service-v2`),
which replaces its hand-written catalog with this one. This plan has no dependencies of
its own.

To see it working, scaffold any conformance fixture and run its test: the generated
inspector names equal the replay-audit categories, an inspector renders the aggregate's
initial state as JSON (through the state codec when the aggregate has snapshots,
otherwise as `{"state": "<vertex>"}`), and the catalog lists one aggregate type per
declared aggregate.


## Progress

- [x] Milestone 1: `keiro-dsl` emits `<prefix>.Inspection` for every context with an
  aggregate or projection catalog; `keiro-dsl-test` covers all emission shapes, and the
  regenerated `conformance-projection-catalog` suite compiles the module and proves its
  runtime behavior. (2026-11-16: the six "Inspection catalog" cases and the updated
  manifest, module-count, and workspace-ownership assertions pass;
  `cabal test keiro-dsl-conformance-projection-catalog` compiles the module under
  `-Werror` and prints every expected line. The remaining `keiro-dsl-test` failures are
  corpus-freshness checks that Milestone 2's regeneration resolves.)
- [ ] Milestone 2: every regenerated conformance suite compiles its Inspection module;
  the snapshot and projections-only suites prove the state-codec and empty-aggregate
  shapes; `scripts/check-conformance-corpus.sh` passes from a clean baseline.
- [ ] Milestone 3: user documentation, both changelogs, and a new ADR describe the module;
  `nix develop -c just verify` passes.
- [ ] Milestone 4: a Keiro release containing this change (proposed `0.25.1.0`) is on
  Hackage and GitHub, and the consuming plans are told the exact version.


## Surprises & Discoveries

- `scaffoldReplayAudit` imports `Keiro.Stream qualified as Stream` beside
  single-segment aggregate aliases, so an aggregate named `Stream` would make its
  `Stream.categoryText` references ambiguous. The Inspection emitter avoids the hazard
  by importing `categoryText` unqualified; ReplayAudit is left unchanged as this plan
  directs. Evidence: the import lines in `scaffoldReplayAudit` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`.
- Adding a context module also changes three count assertions in `keiro-dsl/test/Main.hs`
  that the plan did not name: the reservation Generated count (10 → 11), the
  `order.keiro` total module count (12 → 13), and the workspace ownerless-module count
  (6 → 7).


## Decision Log

- Decision: Emit the module at `contextGeneratedPrefix ctx <> ".Inspection"` with the
  contract names `aggregateInspectorCatalog`, `aggregateInspectors`,
  `inspectionAuditTargets`, and `inspectionProjectionCatalog`, for every context that
  emits a ReplayAudit module (at least one aggregate) or a ProjectionCatalog module (at
  least one projection-catalog declaration). Contexts with neither (for example a
  contract-only service) emit nothing.
  Rationale: research confirmed that ReplayAudit and ProjectionCatalog are both emitted
  once per scaffold context under the same `contextGeneratedPrefix`, and that one
  scaffold run or workspace is exactly one context. The contract placement therefore
  works as written. Emitting for a context with nothing to inspect would force `keiro`
  and `aeson` dependencies onto contract-only fragments.
  Date: 2026-11-16

- Decision: When a context has aggregates but no projection catalog,
  `inspectionProjectionCatalog` is the validated empty catalog
  (`Keiro.Projection.Catalog.emptyProjectionCatalog`); when it has a projection catalog
  but no aggregates, `aggregateInspectorCatalog` and `inspectionAuditTargets` are `[]`
  and `aggregateInspectors` is the empty map. The types never become `Maybe`.
  Rationale: this is the smallest deviation from the contract that consuming plans are
  drafted against. Their code stays identical across services. An empty validated
  catalog is already a supported value (`keiro-ops/test/Main.hs` validates it), and
  mounting it lists no projections rather than failing.
  Date: 2026-11-16

- Decision: Choose the JSON state display from the generated definition's own
  `stateCodec` field. A single generated helper uses
  `Keiro.Inspection.Aggregate.displayViaStateCodec` when the field is `Just codec`, and
  `object ["state" .= pack (show vertex)]` when it is `Nothing`. The generator does not
  duplicate the "has snapshot" predicate.
  Rationale: the state codec is written inline into each `<Agg>EventStreamDef` and not
  exported separately, and `stateCodecFieldLines` in
  `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` already decides it from the aggregate's
  `snapshot` clause. Reading the decided value back from the definition means the
  display cannot drift from what the event stream actually uses, and every aggregate gets
  identical, unconditional generated text. That keeps imports unconditional and
  `-Wunused-imports` clean. The result satisfies the contract: a codec aggregate displays
  via its codec, and any other aggregate displays a JSON object holding the vertex label.
  DSL codecs are always `defaultStateCodec`, whose encoding is
  `{"state": <vertex>, "registers": {...}}`, so both shapes share the `state` key.
  Date: 2026-11-16

- Decision: Do not add an `AppHooks` helper to `keiro-ops`.
  Rationale: `Keiro.Ops.emptyAppHooks` with a record update already expresses the
  read-only mount in three fields, and `docs/user/operations.md` documents exactly that
  pattern. A helper would add a `keiro-ops` API for no new capability, and the generated
  module must not depend on `keiro-ops`, which pulls in migrations and PGMQ. Consumers
  write:
  `emptyAppHooks {replayAudit = Just (OpsAuditConfig inspectionAuditTargets), projectionCatalog = Just (projectionCatalogOperations inspectionProjectionCatalog), aggregates = Just aggregateInspectors}`.
  Date: 2026-11-16

- Decision: No DSL language-version bump, no new `DiagnosticCode`, and no
  generated-Haskell edition change. Release as a PVP minor bump (proposed `0.25.1.0`).
  Rationale: the change adds a generated module and a new library export
  (`scaffoldInspection`). DSL source syntax, checking, and existing generated modules are
  unchanged. Old generated output keeps compiling against the new runtime, so
  regeneration is optional and no `keiro-upgrade` blueprint edge is required. The release
  skill makes the final bump decision at release time: if a breaking change lands in
  `[Unreleased]` first, the release becomes `0.26.0.0`.
  Date: 2026-11-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This section explains everything a newcomer needs. All paths are relative to the keiro
repository root (`/Users/shinzui/Keikaku/bokuno/keiro` on the author's machine).

**Keiro and keiro-dsl.** Keiro is a Haskell event-sourcing framework. An *aggregate* is
a consistency boundary whose state is rebuilt ("folded") from its event stream. Its
state is a *vertex*, a constructor of a generated enumeration such as
`ReservationHeld`, plus a *register file* (`Keiki.Core.RegFile`), a typed record of
named values. `keiro-dsl` (package `keiro-dsl/`) reads `.keiro` specification files and
*scaffolds* Haskell. *Generated* modules carry a `-- @generated by keiro-dsl ...` banner
and are overwritten on every scaffold. *Hole* modules are created once and then owned by
hand. The scaffolder lives in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, a file of about
10,700 lines.

**Context-level generated modules.** Most modules belong to one declaration, such as
`Generated/<Ctx>/<Agg>/EventStream.hs`. A few are emitted once per *context*, the
service named by the specification's `context` (or the workspace's service). Their
namespace is `contextGeneratedPrefix ctx` in `Scaffold.hs` (about line 252): for the
default layout it is `Generated.<Ctx>`, and for the collocated layout it is
`<root>.<Ctx>.Generated` (chapter-service-v2 uses
`ChapterServiceV2.ChapterServiceV2.Generated`). Two such modules matter here:

- `scaffoldReplayAudit :: Context -> Spec -> [ScaffoldModule]` (about line 3828) emits
  `<prefix>.ReplayAudit`, exporting `auditTargets :: [SomeAuditTarget]` with one
  existential target per `NAggregate` node. Process saga aggregates are ordinary
  aggregate nodes and are included. It imports each aggregate's EventStream module
  qualified under the aggregate's name and references `<agg>EventStream` and
  `<agg>Category`, where `<agg>` is `lowerFirst` of the aggregate name. It emits nothing
  when the context has no aggregate.
- `scaffoldProjectionCatalogForService :: Context -> CheckedService -> [ScaffoldModule]`
  (about line 5071, via `scaffoldProjectionCatalogWith`) emits
  `<prefix>.ProjectionCatalog`, exporting among others
  `validatedProjectionCatalog :: Catalog.ValidatedProjectionCatalog`, and a create-once
  `ProjectionCatalogHoles`. It emits nothing unless the spec has a projection target,
  rebuild group, projection revision, external read, or projection owner node (the
  `isCatalogNode` predicate).

Both are registered in exactly two places, which must stay in the same order:
`scaffoldServiceModulesWithBehaviorSource` in `keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`
(about line 329, used by single-spec scaffolding and tests) and `workspaceModules` in
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` (about line 255, which tags each module
`ContextLevel` for ownership attribution). A module's *family*, recorded in scaffold
ledgers as `module-role {"family": ...}`, is derived from the last segment of its module
name by `moduleRole` (Scaffold.hs about line 179), so a new module needs no family
registration. Generated banners are stamped later by `stampGeneratedModule`. Package
dependencies in the emitted Cabal fragment come from node kinds in
`keiro-dsl/src/Keiro/Dsl/Manifest.hs` (about line 191): aggregates add `aeson`, `keiki`,
`keiro`, and `text`, and projection nodes add `keiro`. Those already cover everything the
new module imports.

**Facts about generated aggregates the new module relies on (verified in the source).**
The vertex type always derives `Show`, because `emitVertex` (Scaffold.hs about line
7182) unconditionally emits `deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)`.
Each aggregate's EventStream module (`emitEventStream`, about line 9642) always exports
`<agg>Category :: Stream.StreamCategory <Agg>EventStreamDef`,
`<agg>EventStream :: <Agg>EventStream` (validated), and
`<agg>EventStreamDef :: <Agg>EventStreamDef` (the unvalidated `EventStream` record). The
record's `stateCodec` field is `Just (withFoldFingerprint ... (defaultStateCodec n))`
when the aggregate declares a snapshot clause and `Nothing` otherwise
(`stateCodecFieldLines`/`stateCodecExpr`, about line 9920). The category text is
`lowerFirst` of the aggregate name (about line 9723). Aggregate names are unique
(duplicate declarations are rejected in `keiro-dsl/src/Keiro/Dsl/Validate.hs` about line
2389), and `lowerFirst` is injective on capitalized names, so inspector names, which are
the category texts, are unique and validation of the catalog cannot fail. Event types
derive `Eq`, and the transducer predicate is `HsPred`. These are the same constraints
`SomeAuditTarget` already satisfies in every ReplayAudit module.

**The runtime inspection API.** `keiro/src/Keiro/Inspection/Aggregate.hs` defines:

```haskell
data AggregateInspector phi rs s ci co = AggregateInspector
  { name :: !Text,
    eventStream :: !(ValidatedEventStream phi rs s ci co),
    category :: !(StreamCategory (EventStream phi rs s ci co)),
    mkStream :: !(StreamName -> Maybe (Stream (EventStream phi rs s ci co))),
    displayState :: !(s -> RegFile rs -> Value),
    stateLabel :: !(s -> Text)
  }

aggregateInspector :: (Show s) => Text -> ValidatedEventStream phi rs s ci co -> StreamCategory (EventStream phi rs s ci co) -> (s -> RegFile rs -> Value) -> AggregateInspector phi rs s ci co
displayViaStateCodec :: StateCodec (s, RegFile rs) -> s -> RegFile rs -> Value

data SomeAggregateInspector where
  SomeAggregateInspector :: (BoolAlg phi (RegFile rs, ci), Eq co) => AggregateInspector phi rs s ci co -> SomeAggregateInspector

type AggregateInspectors = Map Text SomeAggregateInspector
aggregateInspectors :: [SomeAggregateInspector] -> Either Text AggregateInspectors  -- rejects duplicate names
listAggregateTypes :: AggregateInspectors -> [AggregateTypeSummary]
aggregateStream :: AggregateInspector phi rs s ci co -> Text -> Either AggregateInspectionError (Stream (EventStream phi rs s ci co))
```

`aggregateInspector` sets `stateLabel = Text.pack . show` and
`mkStream = streamInCategory (categoryText category)`, which is the same mapping
ReplayAudit uses. These are exposed modules of the `keiro` package, as are
`Keiro.ReplayAudit`, `Keiro.Projection.Catalog`, and the re-exported `keiro-core`
modules `Keiro.EventStream`, `Keiro.EventStream.Validate`, and `Keiro.Stream`. Generated
code may therefore import them with only a `keiro` dependency.

`keiro-ops` mounts these through `Keiro.Ops.AppHooks`
(`keiro-ops/src/Keiro/Ops/Embed.hs`), which has the fields
`replayAudit :: Maybe OpsAuditConfig` (wrapping `[SomeAuditTarget]`),
`projectionCatalog :: Maybe ProjectionCatalogOperations` (built by
`Keiro.Projection.Catalog.Operations.projectionCatalogOperations :: ValidatedProjectionCatalog -> ProjectionCatalogOperations`),
and `aggregates :: Maybe AggregateInspectors`. `emptyAppHooks` sets every field to
`Nothing`. The HTTP transport (`keiro-ops-http`) derives its routes from these hooks. The
reference consumer in chapter-service-v2 fills exactly these three fields.

**The conformance corpus.** The directories `keiro-dsl/test/conformance` and
`keiro-dsl/test/conformance-*` contain
committed scaffold output, hand-filled holes, and a `Main.hs` per Cabal test suite
declared in `keiro-dsl/keiro-dsl.cabal`. `keiro-dsl/test/README.md` describes the
workflow. The driver `keiro-dsl-corpus-regen` (package `keiro-dsl/tools/corpus-regen`)
replays the public CLI from each suite's ledger (`keiro-dsl-ledger.*.txt`) and Cabal
fragment (`keiro-dsl-cabal-fragment.*.txt`). It never overwrites create-once modules. It
refuses generated files that no Cabal stanza lists, unless a
`uncompiled-generated <path>` row in `keiro-dsl/test/conformance-corpus-manifest.txt`
exempts them. `scripts/check-conformance-corpus.sh` (also `just conformance-corpus-policy`)
verifies that regeneration changes no byte. `keiro-dsl/test/conformance-skeletons` is
`frozen` and is not regenerated. Thirty-seven regenerated suites emit ReplayAudit
(`conformance` and 36 of the `conformance-*` directories). Of these,
`conformance-bare-containers`, `conformance-calendar-days`,
`conformance-checked-mapping-replay`, `conformance-declarative-router`,
`conformance-projection-catalog`, `conformance-refined-base16`,
`conformance-structural-nominals`, and `conformance-structural-text-sets` also emit a
ProjectionCatalog. Three suites emit a ProjectionCatalog with no aggregate:
`conformance-keyword-segments`, `conformance-mapped-readmodel`, and
`conformance-nominal-query-only`. `conformance-snapshot` is the snapshot-codec fixture.
Regeneration therefore adds 40 Inspection modules.

Two groups of suites need special handling. Eight suites already exempt their ReplayAudit
module, and some of them an aggregate EventStream module, from compilation with
`uncompiled-generated` rows: `conformance-id-domain-migration`, `conformance-process`,
`conformance-process-runtime`, `conformance-process-reactions`,
`conformance-process-timers`, `conformance-process-state-authority`,
`conformance-router`, and `conformance-router-runtime`. Their Inspection module imports
those uncompiled modules, so it cannot be compiled either. Separately,
`conformance-service-package` is not compiled by `keiro-dsl/keiro-dsl.cabal`. Its
generated tree under `keiro-dsl/test/conformance-service-package/runtime/src` belongs to
the hand-maintained package
`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal`,
which lists `Proof.WorkspaceProof.Generated.ReplayAudit` in `other-modules`. The corpus
driver's Cabal inventory check deliberately skips this package (`checkCabalInventory` in
`keiro-dsl/tools/corpus-regen/src/CorpusPlan.hs`), and the package builds with plain
`-Wall`, so a generated module missing from its `other-modules` is silently left
uncompiled.

Corpus Cabal stanzas compile with warnings as errors, including `-Wunused-imports`, and
generated modules must have explicit signatures for every top-level binding and declare
no warning suppressions.

**Unit tests.** `keiro-dsl/test/Main.hs` is the `keiro-dsl-test` hspec suite. It already
tests `scaffoldReplayAudit` ("generates one context target for every aggregate,
including the process saga", about line 9761) and asserts exact module lists for the
`reservation.keiro` fixture (about line 11541). The workspace module tests around lines
13347, 13414, 13447, and 13793 locate context modules by suffix. These lists must gain
the new module.

**Relevant ADRs.** Each is summarized here so you need not read it:

- [ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md):
  inspection is a sanctioned, bounded exception to Keiro's no-UI stance, packaged in
  opt-in sister packages. The generated module adds no web dependency and no runtime
  work. It is inert data until a host mounts it.
- [ADR-54](../adr/0054-aggregate-inspection-reuses-hydration-without-diagnostics-on-the-command-path.md):
  applications explicitly supply aggregate descriptors and display encoders, and
  "snapshot encodings are not implicitly a display contract." This plan makes the choice
  explicit for DSL aggregates only. Their codec is always the generated
  `defaultStateCodec`, whose `state`/`registers` shape ADR-54 already recognizes as a
  display shape. A service that wants a different display keeps writing its own
  inspector. Ordinary command paths gain nothing; the module is only evaluated when
  imported.
- [ADR-19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md):
  generated modules must compile under the recorded edition's default extensions
  (`idiomatic-v1`: GHC2024 plus OverloadedStrings; `idiomatic-v2` adds
  DuplicateRecordFields, NoFieldSelectors, and OverloadedRecordDot). Every top-level
  binding has a signature, and imports are selected by predicates so no import is unused.
  The new module therefore uses no record-dot or field selectors. It reads the codec
  with an ordinary record pattern, which works under both editions, and it needs no local
  extension pragma.
- [ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
  and [ADR-14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md):
  projection catalogs and workspaces are service-level, one per context, which is why
  placing the inspection module beside them is sound.
- [ADR-49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md):
  language-version policy. This change touches no source language, so it needs no
  language bump.

MasterPlan [45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
built the inspection surface this plan feeds. Its aggregate inspection plan,
`docs/plans/278-expose-aggregate-inspection-read-apis.md`, created
`Keiro.Inspection.Aggregate`.

**Release mechanics.** All eight published packages share one PVP version and are
released together by the user-invoked `release` skill (`agents/skills/release/SKILL.md`;
`disable-model-invocation: true`, so an agent cannot start it). The current version is
`0.25.0.0`, released 2026-11-14, and `[Unreleased]` in `CHANGELOG.md` and
`keiro-dsl/CHANGELOG.md` is empty. Downstream Nix consumers get Keiro through runtime
*generations* curated in `mori://shinzui/haskell-nix`
(`docs/guides/compose-on-the-keiro-runtime.md` there). The newest generation, 8, selects
Keiro 0.24.0.0, and chapter-service-v2 pins generation 8. A Hackage release alone does
not reach those consumers until haskell-nix publishes a generation that selects it.
Milestone 4 covers this hand-off.


## Plan of Work

The work adds one emitter, registers it in the two module registries, regenerates the
corpus, proves behavior in three representative suites, documents the result, and
releases it.


### Milestone 1: emit the Inspection module and prove it on one suite

Add `scaffoldInspection :: Context -> CheckedService -> [ScaffoldModule]` to
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, directly after `scaffoldReplayAudit`, and export
it beside `scaffoldReplayAudit` in the module header. Take `CheckedService` so it can
call the same emptiness predicate the projection catalog uses. Factor the
`isCatalogNode`/`catalogNodes` test out of `scaffoldProjectionCatalogWith` into a small
shared function, for example `hasProjectionCatalog :: Spec -> Bool`, so the two cannot
disagree. Use `checkedSpec service` for the node list. The emitter returns:

- `[]` when the spec has no `NAggregate` node and no projection-catalog node.
- Otherwise one `Generated` `ScaffoldModule` with
  `path = T.unpack (T.replace "." "/" moduleName <> ".hs")`, where
  `moduleName = contextGeneratedPrefix ctx <> ".Inspection"`, and
  `origin = "context " <> (.context) spec <> " inspection catalog"`. The origin is the
  ledger owner name. Its `context ` prefix makes the ledger report `ownerKind` `context`.

Emit the module text with the same helpers ReplayAudit uses (`nl`,
`renderGeneratedLanguagePragmas []`, `generatedBanner`, `genPrefixFor`, `lowerFirst`).
For a context with two aggregates `Orders` and `Shipments` and a projection catalog,
the text must be equivalent to the following. Import order and line breaking may follow
the emitter's conventions, and the banner is restamped later.

```haskell
-- @generated by keiro-dsl; do not edit.
--
-- The complete read-only inspection catalog for this service: one aggregate
-- inspector per declared aggregate, the replay-audit targets and the projection
-- catalog. Mount them through Keiro.Ops.AppHooks; see docs/user/operations.md.
module Generated.CatalogDemo.Inspection
  ( aggregateInspectorCatalog
  , aggregateInspectors
  , inspectionAuditTargets
  , inspectionProjectionCatalog
  ) where

import Data.Aeson (Value, object, (.=))
import Data.Text (pack)
import Generated.CatalogDemo.Orders.EventStream qualified as Orders
import Generated.CatalogDemo.ProjectionCatalog (validatedProjectionCatalog)
import Generated.CatalogDemo.ReplayAudit (auditTargets)
import Generated.CatalogDemo.Shipments.EventStream qualified as Shipments
import Keiki.Core (RegFile)
import Keiro.EventStream (EventStream (..))
import Keiro.Inspection.Aggregate (AggregateInspectors, SomeAggregateInspector (..), aggregateInspector, displayViaStateCodec)
import Keiro.Inspection.Aggregate qualified
import Keiro.Projection.Catalog (ValidatedProjectionCatalog)
import Keiro.ReplayAudit (SomeAuditTarget)
import Keiro.Stream (categoryText)

aggregateInspectorCatalog :: [SomeAggregateInspector]
aggregateInspectorCatalog =
  [ SomeAggregateInspector (aggregateInspector (categoryText Orders.ordersCategory) Orders.ordersEventStream Orders.ordersCategory (displayFoldedState Orders.ordersEventStreamDef))
  , SomeAggregateInspector (aggregateInspector (categoryText Shipments.shipmentsCategory) Shipments.shipmentsEventStream Shipments.shipmentsCategory (displayFoldedState Shipments.shipmentsEventStreamDef))
  ]

aggregateInspectors :: AggregateInspectors
aggregateInspectors = case Keiro.Inspection.Aggregate.aggregateInspectors aggregateInspectorCatalog of
  Right inspectors -> inspectors
  Left message -> error ("keiro-dsl generated an invalid aggregate inspector catalog: " <> show message)

inspectionAuditTargets :: [SomeAuditTarget]
inspectionAuditTargets = auditTargets

inspectionProjectionCatalog :: ValidatedProjectionCatalog
inspectionProjectionCatalog = validatedProjectionCatalog

-- The aggregate's own state codec when its definition declares one (snapshot
-- aggregates), otherwise the vertex label.
displayFoldedState :: (Show s) => EventStream phi rs s ci co -> s -> RegFile rs -> Value
displayFoldedState EventStream {stateCodec = Just codec} = displayViaStateCodec codec
displayFoldedState EventStream {stateCodec = Nothing} = \state _ -> object ["state" .= pack (show state)]
```

Two naming hazards shape this text and must be kept. First, the export
`aggregateInspectors` has the same name as the library function
`Keiro.Inspection.Aggregate.aggregateInspectors`. The library one is therefore reached
only through a bare `qualified` import, referenced by its full module name. Aggregate
modules are aliased by single-segment aggregate names, so a multi-segment qualifier can
never collide with one. Second, apart from that, library names are imported unqualified
with explicit import lists and no single-segment alias such as `Stream` or `Text`. An
aggregate named `Stream`, `Text`, or `Aggregate` would otherwise clash with the alias.
ReplayAudit has this latent hazard with `Stream`; record it in Surprises & Discoveries
but do not fix it here. The `Keiki.Core (RegFile)` import passes the generated-code
firewall (`restrictedImports` in Scaffold.hs about line 359 allows `RegFile`).

The variants differ only where a section is empty. They must keep every import used,
because the corpus compiles with `-Wunused-imports` as an error:

- No aggregates (projections-only context): `aggregateInspectorCatalog = []`, keep
  `aggregateInspectors` (it still needs the qualified import, `SomeAggregateInspector`,
  and `AggregateInspectors`), set `inspectionAuditTargets = []`, and omit the
  `displayFoldedState` helper and its imports: `Data.Aeson`, `Data.Text`, `Keiki.Core`,
  `Keiro.EventStream`, `aggregateInspector`, `displayViaStateCodec`, `categoryText`, the
  ReplayAudit import, and all EventStream imports.
- No projection catalog (aggregates-only context): replace the ProjectionCatalog import
  and its binding with the following, importing
  `Keiro.Projection.Catalog (ValidatedProjectionCatalog, Validation (..), emptyProjectionCatalog, validateProjectionCatalog)`.
  `Validation` is exported with the constructors `Failure` and `Success`.

```haskell
inspectionProjectionCatalog :: ValidatedProjectionCatalog
inspectionProjectionCatalog = case validateProjectionCatalog emptyProjectionCatalog of
  Success catalog -> catalog
  Failure diagnostics -> error ("keiro-dsl generated an invalid empty projection catalog: " <> show diagnostics)
```

Register the emitter immediately after `scaffoldProjectionCatalogForService` in both
registries: `<> scaffoldInspection ctx service` in
`scaffoldServiceModulesWithBehaviorSource` (`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs`)
and `<> [attributedStamped ContextLevel m | m <- scaffoldInspection ctx service]` in
`workspaceModules` (`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs`). Both lists must
keep the same order, because tests compare them.

Add hspec cases to `keiro-dsl/test/Main.hs` next to the ReplayAudit test, and import
`scaffoldInspection`. Load fixtures with the existing `checkedServiceOf :: FilePath -> IO CheckedService`
helper (defined near line 15348):

1. `test/fixtures/surge-service.keiro` (two aggregates including a process saga): exactly
   one module with path `Generated/SurgeDemo/Inspection.hs`, two
   `SomeAggregateInspector (aggregateInspector` occurrences, and text containing
   `Hospital.hospitalEventStreamDef` and `Surge.surgeEventStreamDef`.
2. `test/fixtures/projection-catalog.keiro` (aggregates and a projection catalog; the
   spec behind `conformance-projection-catalog`): the text imports `ProjectionCatalog (validatedProjectionCatalog)` and does not mention
   `emptyProjectionCatalog`.
3. `test/fixtures/reservation.keiro` (aggregate, no catalog): the text uses
   `emptyProjectionCatalog`.
4. `test/fixtures/keyword-segments.keiro` (projections only; the spec behind
   `conformance-keyword-segments`): the text contains `aggregateInspectorCatalog = []` and no `EventStream` import.
5. `test/fixtures/contract.keiro` (contract only): the emitter returns `[]`.
6. `firewallBreaches` over the emitted module is `[]`, and `generatedExtensionsEndingIn
   "Inspection.hs"` is `[]` (mirror the ReplayAudit assertion near line 11467).

Update the exact-module-list assertions (about line 11541, which gains
`Generated.HospitalCapacity.Inspection`) and any workspace module counts that now differ.
Run the suite, then run a focused corpus regeneration of `conformance-projection-catalog`.
That produces its `Inspection.hs` and updates its ledger and fragment. Add
`Generated.CatalogDemo.Inspection` to the suite's `other-modules` in
`keiro-dsl/keiro-dsl.cabal`. This is the early producer/consumer check: the generated
text compiles against the real `keiro` types before the change spreads to forty suites.

Extend `keiro-dsl/test/conformance-projection-catalog/Main.hs` to print and assert, with
an exit failure if any check is false:

- the inspector names, `Map.keys aggregateInspectors`, equal `["orders","shipments"]`;
- the names equal the sorted replay-audit categories,
  `sort [target.category | SomeAuditTarget target <- inspectionAuditTargets]`. Use a
  constructor pattern instead of record-dot if the suite's edition requires it. This
  property replaces chapter-service-v2's `uninspectedCategories` guard;
- `map (.name) (listAggregateTypes aggregateInspectors)` gives the same two names with
  `snapshotsConfigured` false. `listAggregateTypes` is the function the `aggregate types`
  ops command calls (`keiro-ops/src/Keiro/Ops/Aggregate.hs` about line 76);
- for the `orders` inspector, applying `displayState` to the definition's `initialState`
  and `initialRegisters` gives `{"state":"OrdersEmpty"}`, and `stateLabel` gives
  `OrdersEmpty`. Reach the definition through
  `Keiro.EventStream.Validate.unvalidated inspector.eventStream`, or pattern-match;
- `aggregateStream inspector "order-1"` resolves to stream name `orders-order-1`;
- `catalogFingerprintText (catalogFingerprint inspectionProjectionCatalog)` equals the
  same expression over `validatedProjectionCatalog`.

Acceptance for Milestone 1: the new `keiro-dsl-test` cases pass and fail if the emitter
registration is removed; `cabal test keiro-dsl-conformance-projection-catalog` passes and
prints the lines shown under Validation and Acceptance.


### Milestone 2: roll the module out across the corpus

Run the full corpus regeneration. Every suite that emits ReplayAudit or ProjectionCatalog
gains `Generated/<Ctx>/Inspection.hs` (or the collocated or rooted equivalent), with
updated ledger `module-role`/`generated` rows and Cabal fragments. Add each new module
to its suite's `other-modules` in `keiro-dsl/keiro-dsl.cabal`, with two exceptions.

First, add `Proof.WorkspaceProof.Generated.Inspection` to `other-modules` in
`keiro-dsl/test/conformance-service-package/runtime/keiro-dsl-conformance-service-runtime.cabal`,
not to `keiro-dsl.cabal`. No check reports this module if it is forgotten, so confirm it
was compiled: `cabal build keiro-dsl-conformance-service-runtime` must print a
`Compiling Proof.WorkspaceProof.Generated.Inspection` line. That package already depends
on `aeson`, `keiki`, `keiro`, and `text`.

Second, a suite that deliberately does not compile a module the Inspection module imports
(its ReplayAudit, an aggregate EventStream, or its ProjectionCatalog) cannot compile the
Inspection module. For each, add an `uncompiled-generated <path>` row under the existing
"Reviewed legacy suites" comment in `keiro-dsl/test/conformance-corpus-manifest.txt`. The
eight suites named in Context and Orientation are the expected set. Record in Surprises &
Discoveries any suite outside that set that needs a row, with the reason. Compiling is the
default, and an exemption needs that reason.

Prove the two remaining shapes at runtime:

- `keiro-dsl/test/conformance-snapshot/Main.hs`: the `reservation` inspector's display of
  the initial state equals `encode` of the definition's state codec on the same
  `(initialState, initialRegisters)`, which is the codec branch. It is a JSON object
  with both `state` and `registers` keys, and `listAggregateTypes` reports
  `snapshotsConfigured = True` with policy `every:100`. Also assert that
  `inspectionProjectionCatalog` is the empty catalog: `catalogInventory` reports no
  sources, or the fingerprint equals that of the validated `emptyProjectionCatalog`.
- `keiro-dsl/test/conformance-keyword-segments/Main.hs` (projections-only):
  `Map.null aggregateInspectors`, `null inspectionAuditTargets`, and the projection
  fingerprint equals that of the suite's `validatedProjectionCatalog`.

Neither of these two stanzas depends on `containers` today (the projection-catalog stanza
does). Add `containers >=0.6 && <0.8` to a stanza's `build-depends` only if its `Main.hs`
imports `Data.Map`. Both checks can avoid it: `null aggregateInspectors` works through
`Foldable`, and the snapshot suite can take its single inspector from
`aggregateInspectorCatalog`.

Acceptance for Milestone 2: `cabal build keiro-dsl:tests` compiles every suite with
warnings as errors; the snapshot and keyword-segments suites pass with the new output;
after committing, `scripts/check-conformance-corpus.sh` reports no drift.


### Milestone 3: documentation, changelogs and ADR

In `docs/user/keiro-dsl-workspaces-and-generated-code.md`, add a short subsection under
"Generated and hand-owned files" describing `<prefix>.Inspection`: its four exports,
when it is emitted, the display rule, and the empty-value behavior. Show the three-line
`emptyAppHooks` mount. State the two visible consequences of the display rule. A
snapshot aggregate displays every register through its codec with no redaction, and
before a register is first written it shows the generated placeholder initial value
(for example the sample ID in `initial<Agg>Regs`). An aggregate without a snapshot clause
displays only its vertex, even when it has registers. A service that needs redaction or
a different shape writes its own inspector instead of mounting the generated one. In `docs/user/operations.md`, after the `AppHooks` example near
line 53, add one paragraph saying DSL services can take all three read-only values from
the generated Inspection module. Both files are OKF documents in the `docs/user` bundle,
so advance each edited file's frontmatter `timestamp` and add a log entry with
`okf log add docs/user -m "..."` (preview first with `--preview`).

Add `[Unreleased]` entries. In `keiro-dsl/CHANGELOG.md`, under `### New Features`: the
new generated module and the `Keiro.Dsl.Scaffold.scaffoldInspection` export, with a note
that regenerating adds one context module that must be added to the consuming Cabal
stanza (the Cabal fragment lists it) and that DSL source and language versions are
unchanged. In the root `CHANGELOG.md`, a one-line **keiro-dsl** summary under
`### New Features`.

Create one ADR capturing the durable decisions from this plan's Decision Log. Suggested
title: "Generated aggregate inspector catalogs cover every DSL aggregate". It covers
completeness by construction, placement beside ReplayAudit and ProjectionCatalog, the
display rule and its relation to ADR-54 (including the unredacted registers and
placeholder initial values described above), empty values instead of `Maybe`, and no
`keiro-ops` dependency. `docs/adr` is a profile-governed OKF bundle, so allocate the
handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR` (do not count
files). Write
`docs/adr/00NN-generated-aggregate-inspector-catalogs-cover-every-dsl-aggregate.md` with
the frontmatter fields existing ADRs use (`type`, `title`, `description`, `timestamp`,
`docId`, `status`, `date`, `originatingPlan`), add an `okf log add` entry, and run
`just adr-validate`. Add a one-sentence cross-reference to the new ADR in ADR-54's
Consequences only if the profile requires timestamp and log updates for it; otherwise
leave ADR-54 untouched.

Acceptance for Milestone 3: `nix develop -c just verify` passes, including
`adr-validate`, `user-documentation-validate`, `dsl-api-boundaries`, the generated-name
policy, and all test suites.


### Milestone 4: release and hand-off

The user, not an agent, starts the release by invoking the `release` skill (for example
`/release minor`). That skill owns version bumps, internal bounds, changelog sections,
the `keiro-upgrade` blueprint edge decision, `just release-prepare`, `just release-gate`,
artifacts, Hackage upload, tags, and the GitHub release. This plan proposes `0.25.1.0`,
a PVP minor bump, because the change is additive: a new generated module and a new
library export, with no removed or changed API, no new `DiagnosticCode`, and no language
or edition change. Record in the release that no upgrade edge is needed, because old
generated output compiles unchanged against the new runtime and regeneration is
optional. If `[Unreleased]` contains a breaking entry by then, the release is
`0.26.0.0`. Either way, record the actual version in this plan's Outcomes section.
`release-prepare` restamps every generated banner in the corpus with the new version.
That is expected.

After publication, add a dated note to Outcomes & Retrospective naming the exact released
version, so the consuming plans B
(`mori://shinzui/seihou-modules/plans/15-mount-the-keiro-ui-inspection-surface-in-the-haskell-keiro-project-server-starter`)
and D
(`mori://tan/chapter-service-v2/plans/1-adopt-the-generated-aggregate-inspector-catalog-in-chapter-service-v2`)
can set their bounds. Record that Nix consumers additionally need a
`mori://shinzui/haskell-nix` runtime generation selecting that Keiro version. Generation
8 selects 0.24.0.0, and none selects 0.25.x yet. Producing that generation is
haskell-nix work (its `update-family` skill, `mori://shinzui/haskell-nix/skills/update-family`)
and is not part of this plan. Also note for D that chapter-service-v2 is on Keiro 0.24
(generation 8), so adopting any 0.25.x release also crosses the 0.24.0.0 → 0.25.0.0
breaking edge (durable tracing changes; see `CHANGELOG.md` 0.25.0.0 and
`blueprints/keiro-upgrade/`).

Acceptance for Milestone 4: `https://hackage.haskell.org/package/keiro-dsl-<version>`
and the seven sibling package pages return HTTP 200;
`nix develop -c just release-consumer published` passes; `gh release view keiro-<version>`
shows a non-draft release; and the published `keiro-dsl` tarball's `Keiro/Dsl/Scaffold.hs`
exports `scaffoldInspection`.


## Concrete Steps

Run all commands from the keiro repository root inside the development shell. These
commands share a workspace lock. Do not run raw `cabal` commands at the same time as
`just verify`, `just corpus-regen`, or the release recipes.

Milestone 1, after editing the emitter, registries, and tests:

```bash
nix develop -c cabal test keiro-dsl-test --test-options='--match "Inspection"'
nix develop -c cabal test keiro-dsl-test
nix develop -c python3 scripts/release_workflow.py locked -- \
  cabal run -v0 keiro-dsl-corpus-regen -- regenerate \
  --only keiro-dsl/test/conformance-projection-catalog
git status --short keiro-dsl/test/conformance-projection-catalog
```

The status should show the new `Generated/CatalogDemo/Inspection.hs`, a modified ledger,
and a modified Cabal fragment. Banner-only changes elsewhere in the suite mean the stamp
changed and should be investigated. After adding the module to the stanza and extending
`Main.hs`:

```bash
nix develop -c cabal test keiro-dsl-conformance-projection-catalog
```

Milestone 2:

```bash
nix develop -c just corpus-regen
git status --short keiro-dsl/test | grep 'Inspection.hs'
nix develop -c cabal build keiro-dsl:tests
nix develop -c cabal build keiro-dsl-conformance-service-runtime
nix develop -c cabal test keiro-dsl-conformance-snapshot keiro-dsl-conformance-keyword-segments
```

`git status` should list 40 new `Inspection.hs` files. The focused regeneration uses the
same `release_workflow.py locked` wrapper as `just corpus-regen`, so it takes the
workspace lock.

Commit the regenerated corpus together with the Cabal and manifest edits, then:

```bash
scripts/check-conformance-corpus.sh
```

It refuses to start if corpus paths are dirty, so commit first.

Milestone 3:

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add docs/adr --kind Addition -m "Record that generated aggregate inspector catalogs cover every DSL aggregate." --preview
okf log add docs/user -m "Document the generated Inspection module and its read-only AppHooks mount." --preview
nix develop -c just verify
```

Rerun each `okf log add` without `--preview` after reviewing it. Commit each milestone
with a Conventional Commit and the plan trailer, for example:

```text
feat(keiro-dsl): generate an aggregate inspector catalog per service context

Emit <prefix>.Inspection beside ReplayAudit and ProjectionCatalog with one
validated inspector per declared aggregate.

ExecPlan: docs/plans/336-generate-an-aggregate-inspector-catalog-for-every-keiro-dsl-aggregate.md
```


## Validation and Acceptance

Required acceptance is behavioral and observable through tests and the corpus.

`cabal test keiro-dsl-test` passes with the new "Inspection" cases. Removing the
`scaffoldInspection` registration from `ScaffoldRun.hs` makes the exact-module-list test
and the new cases fail.

`cabal test keiro-dsl-conformance-projection-catalog` prints lines equivalent to the
following and exits 0:

```text
inspection aggregate names: ["orders","shipments"]
inspection names equal replay-audit categories: True
inspection aggregate types: [("orders",False),("shipments",False)]
orders initial display: {"state":"OrdersEmpty"}
orders initial label: OrdersEmpty
orders stream for order-1: orders-order-1
inspection projection catalog is the generated catalog: True
```

`cabal test keiro-dsl-conformance-snapshot` additionally prints something like:

```text
reservation display uses the state codec: True
reservation display keys: ["registers","state"]
reservation snapshot policy: every:100
inspection projection catalog is empty: True
```

`cabal test keiro-dsl-conformance-keyword-segments` additionally prints:

```text
inspection aggregates empty: True
inspection audit targets empty: True
inspection projection catalog is the generated catalog: True
```

The whole corpus compiles (`cabal build keiro-dsl:tests`), and
`scripts/check-conformance-corpus.sh` reports no regeneration drift from the committed
baseline. `nix develop -c just verify` passes before the release.

The full HTTP path (keiro-ui listing these aggregates under `/keiro` against a live
database) is not required here. The consuming plans B and D exercise it in real services.
The type-level fit with `Keiro.Ops.AppHooks` is exact, because its fields are the very
`keiro` types the module exports. That is the same shape chapter-service-v2's
hand-written `Hooks.hs` already compiles against.


## Idempotence and Recovery

Scaffolding is idempotent. A second run over unchanged input reports every generated
module `Unchanged` and never touches create-once modules. The corpus driver never
force-overwrites and never commits. If a regeneration produces an unexpected diff, inspect
it with `git diff`, fix the emitter, and rerun. To discard a bad regeneration of one
suite, run `git checkout -- keiro-dsl/test/<suite>` and
`git clean -n keiro-dsl/test/<suite>`, then rerun `git clean -f` on reviewed paths.
Never hand-edit a generated module to make a check pass.
`scripts/check-conformance-corpus.sh` refuses dirty corpus paths, so commit first, and do
not use `--allow-dirty` to bypass it.

The change is additive. Reverting the emitter and its registrations, then regenerating,
removes every Inspection module. The ledgers then report them as stale, which is the
driver's normal handling of removed output. The release step is irreversible once
uploaded to Hackage. The release skill stops on any failed gate before upload. If an
upload fails partway, follow that skill's rule: never publish a dependent after a failed
dependency.


## Interfaces and Dependencies

This plan has no hard dependencies. It produces the interface the two consuming plans
depend on. The interface lives in the consuming service's generated layer, not in a Keiro
package:

```haskell
-- <contextGeneratedPrefix>.Inspection, e.g.
-- Generated.<Ctx>.Inspection (default layout) or
-- ChapterServiceV2.ChapterServiceV2.Generated.Inspection (collocated, rooted layout)
aggregateInspectorCatalog :: [Keiro.Inspection.Aggregate.SomeAggregateInspector]
aggregateInspectors :: Keiro.Inspection.Aggregate.AggregateInspectors   -- Map Text SomeAggregateInspector, keyed by category text
inspectionAuditTargets :: [Keiro.ReplayAudit.SomeAuditTarget]
inspectionProjectionCatalog :: Keiro.Projection.Catalog.ValidatedProjectionCatalog
```

Guarantees: one inspector per declared aggregate, including process saga aggregates. The
inspector `name` equals the aggregate's category text, which equals the matching
`AuditTarget.category`. `stateLabel` is the vertex's `show`. `displayState` is
`displayViaStateCodec` of the aggregate's state codec when it has one, otherwise
`{"state": "<show vertex>"}`. `aggregateInspectors` is total: duplicate names are
impossible by construction, and a violation fails loudly on evaluation. An absent
section yields `[]`, `Map.empty`, or the validated empty projection catalog. The module
exists whenever the context has at least one aggregate or projection-catalog
declaration. The library-side addition is
`Keiro.Dsl.Scaffold.scaffoldInspection :: Context -> CheckedService -> [ScaffoldModule]`.

A consumer mounts the read-only surface with existing `keiro-ops` APIs:

```haskell
import Keiro.Ops (AppHooks (..), OpsAuditConfig (..), emptyAppHooks)
import Keiro.Projection.Catalog.Operations (projectionCatalogOperations)

operationsHooks :: AppHooks
operationsHooks =
  emptyAppHooks
    { replayAudit = Just (OpsAuditConfig inspectionAuditTargets),
      projectionCatalog = Just (projectionCatalogOperations inspectionProjectionCatalog),
      aggregates = Just aggregateInspectors
    }
```

Libraries whose choice matters: `keiro` (the `Keiro.Inspection.Aggregate`,
`Keiro.ReplayAudit`, and `Keiro.Projection.Catalog` APIs, plus the `keiro-core`
re-exports `Keiro.EventStream` and `Keiro.Stream`), `keiki` (`Keiki.Core.RegFile`),
`aeson`, and `text`. The aggregate node kind already contributes all of them to the
emitted Cabal fragment, so no manifest dependency changes.

Downstream: consumers B
(`mori://shinzui/seihou-modules/plans/15-mount-the-keiro-ui-inspection-surface-in-the-haskell-keiro-project-server-starter`)
and D
(`mori://tan/chapter-service-v2/plans/1-adopt-the-generated-aggregate-inspector-catalog-in-chapter-service-v2`)
need the Milestone 4 release. Plan C
(`mori://tan/tan-seihou-modules/plans/7-enable-keiro-ui-inspection-by-default-in-the-tan-keiro-project-recipe`)
depends on B, not on this plan. Nix-based consumers also need a
`mori://shinzui/haskell-nix` runtime generation that selects the released Keiro version.


## Revision Notes

2026-11-16: Review against the working tree. The design, the cited source locations, and
the expected test output were confirmed. Milestone 2 was made concrete where the tree
differs from the original text: `conformance-service-package` is compiled by its own
Cabal file and is invisible to the inventory check, eight suites are named as needing
`uncompiled-generated` rows, the snapshot and keyword-segments stanzas lack `containers`,
and the corpus count is 40 new modules including the plain `conformance` suite.
Milestone 3 now requires the documentation and ADR to state that the codec display shows
unredacted registers and placeholder initial values. The focused regeneration command
now takes the workspace lock.
