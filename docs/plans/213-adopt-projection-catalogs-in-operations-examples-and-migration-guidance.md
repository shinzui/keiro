---
id: 213
slug: adopt-projection-catalogs-in-operations-examples-and-migration-guidance
title: "Adopt projection catalogs in operations examples and migration guidance"
kind: exec-plan
created_at: 2026-08-07T23:36:52Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
master_plan: "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
---

# Adopt projection catalogs in operations examples and migration guidance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, adopters can copy a complete catalog-backed application rather than assemble
projection, table, registration, rebuild, and operations lists independently. `jitsurei` uses one
validated catalog for normal inline/async application, query-model registration, a normalized
mixed-policy rebuild, dry-run inventory, execution, status, resume, and abandon. The example
proves that application migrations and SQL handlers remain application-owned.

The user documentation explains both hand-written and generated catalogs, gives a staged migration
from Keiro 0.11 APIs, and states the structural proof boundary. The embeddable operator surface from
plan 208 consumes a catalog-backed adapter rather than `Map Text (OpsEnv -> IO ExitCode)`. If that
external MasterPlan has not yet created `keiro-ops`, this plan lands the runtime adapter and
`jitsurei` acceptance surface first, records the integration as pending, and completes the command
mount as soon as plan 208's `AppHooks` module exists; it does not create a competing command tree.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Add a stable application/operator adapter for catalog inventory, dry-run, start, inspect,
      resume, and abandon without caller-supplied projection or target maps.
- [x] Migrate `jitsurei` live assembly and query registration to one hand-written catalog and add a
      normalized clear/preserve brownfield rebuild fixture.
- [x] Adopt the generated language-5 catalog after plan 212, or document the hand-written/generated
      delta if that soft dependency is still in progress.
- [ ] Replace plan 208's manual rebuild map with the catalog adapter, exercise text/JSON preview and
      `--force`, and reconcile both MasterPlans. Blocked at the command mount only: `keiro-ops`
      and `AppHooks` do not exist; plan 208 and MasterPlan 31 now name the landed adapter.
- [x] Publish migration, API, runbook, example, and changelog documentation; pass the available
      example and full repository verification, and record the pending operator gate.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-08-08: `keiro-ops` and `Keiro.Ops.Embed.AppHooks` remain absent. The runtime adapter,
  application example, and documentation can land, but text rendering, `--force`, and command
  acceptance cannot be implemented without creating the forbidden parallel command tree.
- 2026-08-08: The first real example assertion exposed the runner's intentional cursor boundary:
  an event at global position 0 produces an exclusive captured head of 1. The acceptance test now
  names both facts instead of treating the last event position as the head cursor.
- 2026-08-08: A preserved brownfield row can make replay technically complete but promotion
  operationally unsafe. An application verifier now blocks that row, and the example proves the
  failed group continues to fence appends until repair and exact-run resume succeed.


## Decision Log

Record every decision made while working on the plan.

- Decision: Put the operator-neutral catalog actions in `keiro`, then mount them in `keiro-ops`.
  Rationale: The runtime package owns validated rebuild semantics, while `keiro-ops` owns command
  parsing, rendering, preview, and confirmation. This permits application embedding without
  duplicating the rebuild procedure or coupling core Keiro to optparse.
  Date: 2026-08-07

- Decision: Do not create a temporary second ops command tree when `keiro-ops` is absent.
  Rationale: Plan 208 already owns the embeddable command contract. A parallel example-only parser
  would create the exact drift this initiative removes. `jitsurei` may call the operator-neutral
  adapter directly in tests until that package exists.
  Date: 2026-08-07

- Decision: Prove both destructive-clear and preserve-and-reconcile behavior in one normalized
  example group.
  Rationale: A single-table happy path does not exercise the production failure that motivated the
  request: foreign keys, incomplete brownfield roots, and safely replayable derived children.
  Date: 2026-08-07

- Decision: Keep the old runtime APIs supported but label them unmanaged during staged adoption.
  Rationale: The catalog must be additive until examples, DSL generation, and operator integration
  prove the path. Silent semantic changes to existing `runCommandWithProjections` or one-table
  rebuild callers would be a migration hazard.
  Date: 2026-08-07

- Decision: Name the landed hook `ProjectionCatalogOperations` and keep its reports as explicit
  versioned envelopes rather than an effect-polymorphic operations record.
  Rationale: The validated catalog already closes over handler behavior. Pure inventory/preview,
  read-only registered preview, and explicit effectful actions make mutation boundaries visible
  and let the future CLI render the same values without accepting replacement fleet lists.
  Date: 2026-08-08

- Decision: Use the dedicated candidate-language-5 conformance service as the generated adoption
  context and compare its semantic inventory dimensions with hand-written jitsurei.
  Rationale: It already imports one generated context facade and executes the runtime catalog;
  copying generated modules into jitsurei would create a second generated corpus without adding a
  distinct guarantee.
  Date: 2026-08-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

The available runtime and application work is complete. `ProjectionCatalogOperations` exposes
versioned inventory, pure and registered-state preview, and start/inspect/resume/abandon without
caller-provided fleet lists. `jitsurei` uses one validated catalog for managed inline and async
application, startup registration, query binding, and a mixed preserve/clear group. Its acceptance
path proves fixed-head replay, verification failure, durable inspection, append fencing, operator
repair, exact-run resume, brownfield preservation, derived-target reconstruction, and suppression
of a live-only side effect.

The generated conformance context proves the matching candidate-language-5 dimensions through one
generated facade. Canonical API, migration, runbook, and guide documentation now distinguish the
available adapter from the planned CLI. The remaining gap is external and explicit: MasterPlan 31
has not created `keiro-ops`, so this plan cannot truthfully mark command rendering, `--force`, or
embedding complete.

Verification on 2026-08-08 passed with 436 `keiro-test` examples, 22 `jitsurei-test` examples,
615 `keiro-dsl-test` examples, the generated projection-catalog conformance executable, the
offline changed-document link check (141 links checked, 0 errors), and the complete `just verify`
gate. The unavailable `keiro-ops-test` gate remains coupled to the pending command-package
milestone above rather than being represented as a passing test.


## Context and Orientation

This plan hard-depends on [plan 211](211-replay-catalogued-projections-deterministically-and-resumably.md).
It soft-depends on [plan 212](212-generate-projection-catalogs-from-keiro-dsl-and-classify-their-evolution.md):
hand-written runtime adoption can start after plan 211, but the final generated example and docs
should use language 5 when available.

`jitsurei/src/Jitsurei/ReadModels.hs`, `Jitsurei/OrderStream.hs`, and `jitsurei/app/Main.hs`
currently demonstrate Keiro's independent read-model/projection APIs. `jitsurei/Database.hs` and
the example migrations own application schema. `jitsurei/test/Main.hs` is the acceptance location
for repeatable behavior; command transcripts may supplement but not replace automated tests.

The relevant current user docs are `docs/user/read-models-and-projections.md`,
`docs/user/api-reference.md`, `docs/user/operations.md`, and
`docs/user/migration-ownership.md`. `docs/guides/project-read-models.md` and
`docs/guides/brownfield-migration-and-transducer-modeling.md` provide longer-form design guidance.
Update these existing paths rather than creating near-duplicate guides. The root `README.md`,
package changelogs, user index, and guide index must point to the canonical documents.

[Plan 208](208-make-keiro-ops-embeddable-and-document-the-operational-surface.md) belongs to
[MasterPlan 31](../masterplans/31-build-the-keiro-ops-operational-cli.md). It originally proposed
an application-owned `Map Text (OpsEnv -> IO ExitCode)` for rebuilds; plan 208 has now been revised
to wait for this typed adapter instead. At planning time no `keiro-ops` directory exists, so its
prerequisite plans have not created the package. This plan owns the
catalog-backed rebuild adapter and the rebuild portion of `AppHooks`; plan 208 retains the command
tree, workflows, replay audit, text/JSON rendering, preview, `--force`, and embedding surface.
Whichever plan executes second must consume the already-landed interface and update both plans'
Decision Logs.

An **operator-neutral adapter** exposes serializable inventory/preview/status values and explicit
start/resume/abandon actions over `ValidatedProjectionCatalog`; it has no CLI parser or renderer.
A **dry run** validates the catalog and registered fingerprint, resolves the group, lists targets
and reset policies, sources and captured-head strategy, affected subscriptions/dedup identities,
verification hooks, and destructive actions without starting or locking a rebuild. Execution
requires a separate request and is never triggered by rendering inventory.

[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) and
`docs/user/migration-ownership.md` require example targets to remain in consumer migrations.
[ADR 20](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md) governs the
generated adoption path. The catalog ADR created under plan 209 governs runtime and operator
claims. The motivating external decision remains
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Plan of Work

### Milestone 1: Stabilize operator-neutral catalog actions

Add `keiro/src/Keiro/Projection/Catalog/Operations.hs` or the smallest equivalent public module.
It consumes `ValidatedProjectionCatalog` and the plan-211 rebuild service. Expose pure inventory
and preview plus effectful start, inspect, resume, and abandon. Inputs identify only a catalog group
and operational options; callers cannot supply target, source, adapter, projection-name,
subscription, or dedup lists.

Define versioned JSON-friendly report types independently from any CLI renderer. Inventory shows
stable projection/group/target/query/source identities and live/replay/reset policies. Preview
shows validation/fingerprint status, clear versus preserve targets, lock/fence scope, derived
dedup/subscription resets, replay-source ordering/captured-head strategy, verification hooks, and
whether the request is destructive. Redact database connection details and event payloads.

Pure preview must perform no database effect. A registered-state preview may read lifecycle state
but must not acquire a long-lived fence, create a run, truncate, or reset. Effectful execution uses
plan 211 and returns its structured run report. Unit tests use one valid and one invalid catalog to
prove invalid inventory/execution fails before effects.

### Milestone 2: Convert `jitsurei` to one hand-written catalog

Refactor `Jitsurei.ReadModels` and the live wiring in `Jitsurei.OrderStream`/`Jitsurei` so one
catalog declaration owns the example projections, physical targets, rebuild groups, query-model
bindings, sources, async identities, and policies. Replace startup registration lists and inline
projection lists with catalog-derived views. Keep handlers, query functions, row codecs, and
qualified table constants application-owned.

Extend the example's consumer-owned migrations with a normalized projection group: a brownfield
root target set to preserve-and-reconcile and a foreign-key child/derived target set to
clear-before-replay. Seed one root with full event history and one without corresponding functional
history. Add a replay-specific adapter for a live handler that also performs a test-observable side
effect; rebuild must update the read model without repeating that side effect.

In `jitsurei/test/Main.hs`, exercise normal typed inline application, async application,
registration, inventory, dry-run, fixed-head group rebuild, crash/resume, verification, and final
query. Assert the no-history brownfield root remains, the event-covered records reconcile, the
derived child rebuilds, and every operator report is derived from the same catalog. Assert no
application target appears in a Keiro migration.

If plan 212 is complete, migrate a second small context or this same example to a checked
language-5 spec and import only its generated projection-catalog facade. Compare its inventory to
the hand-written semantic fixture. If plan 212 is still active, record this checklist item as
pending rather than copying unstable generated output by hand.

### Milestone 3: Mount the catalog in the embeddable operations surface

First inspect whether plan 208's `keiro-ops` package and `Keiro.Ops.Embed.AppHooks` exist. If they
do, replace the manual rebuild map with an optional catalog operations hook. If they do not, update
plan 208's design now, leave the operator-neutral adapter complete and tested, and do not create a
parallel CLI; return to this milestone after the prerequisite package lands. This is an explicit
cross-MasterPlan integration gate, not permission to mark the milestone complete without a
command.

The final `rebuild --list`, `rebuild <group>`, `rebuild status <run>`, `rebuild resume <run>`, and
`rebuild abandon <run>` commands use the adapter. Follow plan 208's final command spelling if its
parser already shipped. Text and JSON rendering consume the same report values. A mutating start,
resume, or abandon obeys the established schema handshake, preview, explicit `--force`, exit-code,
and error-envelope conventions. Inventory/list and dry-run remain non-mutating.

Mount the command tree in `jitsurei-demo` exactly as plan 208 specifies. Capture a reproducible
acceptance transcript for list, preview, forced rebuild, status, simulated failure, resume, and
final success in both text and JSON. Tests assert that an absent catalog hides catalog rebuild
commands, while a mounted catalog exposes only validated groups; there is no application rebuild
map alongside it.

Update plan 208 and MasterPlan 31 to record that target/reset/replay semantics come from
MasterPlan 32 and that the broader ops package still owns rendering and embedding. Update this
MasterPlan's progress and surprises with the actual integration order.

### Milestone 4: Publish the migration and operational contract

Rewrite `docs/user/read-models-and-projections.md` around the four identities and one-catalog
assembly. Include hand-written and language-5 generated examples, typed source selection, async
registration, explicit live versus replay handlers, clear versus preserve targets, fixed-head
completion, and normal/fenced outcomes.

Add a staged migration section or dedicated subsection in the canonical guide:

1. inventory existing read models, physical tables, projection handlers, subscriptions/dedup keys,
   sources, and rebuild procedures;
2. group targets that must fence/reset/promote atomically;
3. choose reset policy per target and replay policy per projection;
4. add replay-specific safe adapters and verification;
5. construct and validate a catalog while legacy paths still run;
6. switch registration/live selection, then rebuild/ops, then DSL generation; and
7. retain or remove unmanaged compatibility calls only after inventory/diff evidence agrees.

State the closed-world limit prominently: catalog validation cannot discover undeclared tables or
prove arbitrary SQL writes. Removing an owner while retaining a target is a validation error;
removing the entire declaration requires persisted inventory or DSL diff. State that Keiro never
creates or migrates application targets.

Update `docs/user/api-reference.md`, `docs/user/operations.md`,
`docs/user/migration-ownership.md`, the two relevant guides, indexes, `README.md`, and changelogs.
Use the catalog-backed command narrative in operations docs only after Milestone 3 exists; until
then label it planned, not available. Amend the ADR only if adoption reveals a durable contract
change. Complete the plan after docs link checks, example/operator tests, and `just verify` pass.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Confirm the external integration state before
Milestone 3:

```console
test -d keiro-ops && rg -n "data AppHooks|rebuilds|opsCommandTree" keiro-ops
```

An exit status indicating `keiro-ops` is absent means the milestone waits on plan 208; it does not
authorize an alternative parser. Record that result in Progress.

Format and run focused runtime/example tests after Milestones 1 and 2:

```console
nix fmt
cabal test keiro-test
cabal test jitsurei-test
```

Expected successful tail:

```text
Test suite keiro-test: PASS
Test suite jitsurei-test: PASS
```

After the ops package exists, use its actual Cabal component names discovered from
`keiro-ops/keiro-ops.cabal`:

```console
cabal build keiro-ops jitsurei
cabal test keiro-ops-test
cabal run jitsurei-demo -- ops rebuild --list --json
cabal run jitsurei-demo -- ops rebuild <group> --dry-run --json
```

Replace `<group>` in the recorded transcript with the stable jitsurei group identity. Execute a
mutating acceptance rebuild only against the disposable local jitsurei database and with the
command's required confirmation flag.

Run final gates:

```console
git diff --check
just verify
```

If plan 212 is complete, `cabal test keiro-dsl:tests` and the generated conformance suite are part
of the final evidence. Record exact commands and output summaries in Outcomes & Retrospective.


## Validation and Acceptance

Acceptance requires all of the following:

1. Search the migrated jitsurei runtime and find one catalog declaration, no startup projection
   name list, no independent rebuild target list, no independent subscription/dedup reset list,
   and no ops rebuild map. Typed live selection and heterogeneous inventory come from the same
   validated value.
2. Normal inline and async event handling updates the expected targets. When a rebuild starts, a
   concurrent live request receives the typed fenced outcome and does not append/write; normal
   traffic succeeds again only after atomic promotion.
3. Dry-run JSON and text identify the same group, targets, clear/preserve actions, sources,
   adapters, resets, verification, and fingerprint. They create no run and change no table.
4. The normalized example rebuild clears foreign-key-related derived targets together, preserves
   the brownfield root lacking functional history, reconciles the event-covered root, suppresses
   the live-only side effect through its replay adapter, resumes after injected failure, verifies,
   and promotes.
5. `jitsurei` migrations, not Keiro migrations or DSL generation, create every example target.
   Documentation names the arbitrary-SQL and total-declaration-removal limits accurately.
6. If language-5 generation has landed, its catalog facade compiles and yields the same inventory
   semantics as the hand-written fixture. If not, the soft-dependency item remains visibly pending
   and MasterPlan 32 is not marked fully complete.
7. Once plan 208 exists, its embedded list/preview/start/status/resume/abandon behavior uses the
   catalog adapter, preserves preview/`--force`/JSON/exit-code contracts, and hides commands when
   no catalog is mounted. Both plan documents describe the same interface.
8. An adopter following only the canonical read-model guide and migration checklist can introduce
   the catalog before switching traffic, identify destructive actions, and retain a rollback path.
9. Focused runtime, jitsurei, DSL when applicable, ops, ADR if amended, and `just verify` gates pass.


## Idempotence and Recovery

Inventory and dry-run are read-only and repeatable. Jitsurei setup uses its existing disposable
database workflow; migrations are forward-only, so correct a released example migration with a
new migration. Catalog registration is idempotent only for the same durable fingerprint.

The staged adoption keeps legacy APIs available until live selection and registration have moved
and tests agree. If catalog validation fails, no effect occurs and the application can continue on
the unchanged legacy assembly while declarations are corrected. Do not run legacy and catalog
handlers simultaneously; switch one assembly point at a time to avoid double application.

A failed rebuild remains fenced and is resumed or abandoned through plan 211. Never demonstrate
recovery by deleting progress, inserting dedup rows, manually marking a group live, or truncating a
preserved target. The jitsurei acceptance database is disposable, but the documented procedure
must be safe for production data.

Documentation and generated examples are repeatable. Preserve hand-owned holes and unrelated user
changes. If plan 208 lands after this plan's runtime/example work, re-enter Milestone 3, mount the
already-stable adapter, and update both living plans rather than forking the interface.


## Interfaces and Dependencies

`Keiro.Projection.Catalog.Operations` owns an operator-neutral surface equivalent to:

```haskell
data ProjectionCatalogOperations
data CatalogInventoryReport
data RebuildPreview
data RegisteredRebuildPreview
data CatalogRunReport

projectionCatalogOperations
  :: ValidatedProjectionCatalog
  -> ProjectionCatalogOperations

catalogInventoryReport
  :: ProjectionCatalogOperations
  -> CatalogInventoryReport

previewGroupRebuild
  :: ProjectionCatalogOperations
  -> RebuildGroupId
  -> Either CatalogOpsError RebuildPreview

startGroupRebuild
  :: ProjectionCatalogOperations
  -> RebuildGroupId
  -> RebuildOptions
  -> Eff es (Either CatalogOpsError CatalogRunReport)
```

The final module may expose resume, inspect, and abandon as record fields or functions, following
Keiro's established style. Report types have stable `ToJSON` encodings and no CLI dependencies.
The adapter delegates execution to plan 211 and cannot manufacture catalog membership.

When available, `Keiro.Ops.Embed.AppHooks` replaces its `Map Text (OpsEnv -> IO ExitCode)` field
with an optional mounted `ProjectionCatalogOperations` at the package's pinned effect/runtime boundary.
`keiro-ops` owns parsers, renderers, confirmation, and exit codes. `jitsurei` owns application
migrations, handlers, verification hooks, and the concrete catalog value. `keiro-dsl` owns only
generated declarations and create-once holes.

No new third-party dependency is expected. If implementation reaches for optparse, Aeson, Hasql,
or APIs from `mori://shinzui/kiroku/packages/kiroku-store` not already present, locate the
authoritative project with Mori, inspect its local source/docs, and verify the current release
before changing package bounds.
