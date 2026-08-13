---
id: 249
slug: make-catalog-adoption-scoped-truthful-and-registry-complete
title: "Make catalog adoption scoped, truthful, and registry-complete"
kind: exec-plan
created_at: 2026-08-12T23:55:34Z
intention: "intention_01kzw6dk7qe1qayx2qdz6vcqfd"
master_plan: "docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md"
---

# Make catalog adoption scoped, truthful, and registry-complete

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-ops rebuild adopt GROUP...` is the operator command that accepts a reviewed
projection-catalog change. Today it lies twice. First, the non-forced preview renders the
adoption state of the *entire* catalog while the `--force` execution adopts *only the named
groups*, so an operator who approves the preview and re-runs the printed force command can
believe they reconciled everything when they did not — the service still refuses to start
with `RegisteredGroupSliceDrift` on the group the command never touched. Second, the
adoption transaction "reconciles" query-model registration rows with an UPDATE that
silently matches zero rows: a query model that was added or renamed in the catalog gets no
registry row (or leaves its old-name row behind, permanently marked `live` for a model no
code serves), yet adoption stamps the group slice as adopted and reports success.

After this plan, the preview an operator approves and the plan `--force` executes are the
same plan: every preview row is annotated with whether the named groups cover it, the
preview warns when out-of-scope groups still drift, and a request naming a group the
catalog does not contain fails in preview exactly as it would fail in execution. Adoption
itself becomes registry-complete: it inserts registration rows that are missing, updates
rows that exist, deletes old-name rows that no registration in the entire catalog claims
(listing the deletion in the preview first), and reports a per-registration outcome —
`adopted`, `inserted`, or `orphaned-old-name` — for everything it touched. Both fixes are
proven by database-backed tests that fail on the current code and pass after the change.

This is EP-4 of MasterPlan 39
(docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md)
and gates the 0.12.0.0 release: the adoption report envelopes become compatibility
surfaces at the first stable tag.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-08-13 04:16Z) Milestone 1: red test in `keiro/test/CatalogEvolutionSpec.hs` proving a renamed
      query registration is silently no-opped and its old-name row stranded.
- [x] (2026-08-13 04:16Z) Milestone 1: red test in `keiro/test/CatalogEvolutionSpec.hs` proving an added
      query registration gets no row from adoption.
- [x] (2026-08-13 04:16Z) Milestone 1: red tests in `keiro-ops/test/Main.hs` proving the non-forced adopt
      preview carries no scope annotation and does not mirror execution's
      group-not-in-catalog refusal.
- [x] (2026-08-13 04:16Z) Milestone 1: red transcripts captured in Surprises & Discoveries.
- [x] (2026-08-13 04:26Z) Milestone 2: registration disposition types, reworked `adoptTx`, orphan detection
      and deletion, and registration-aware `previewCatalogAdoption` in
      `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`; facade exports updated.
- [x] (2026-08-13 04:26Z) Milestone 2: `keiro/test/CatalogEvolutionSpec.hs` updated and extended;
      `cabal test keiro-test` green.
- [ ] Milestone 3: scoped preview, v2 report envelopes, and JSON in
      `keiro/src/Keiro/Projection/Catalog/Operations.hs`.
- [ ] Milestone 3: scoped rendering and wiring in `keiro-ops/src/Keiro/Ops/Rebuild.hs`;
      `cabal test keiro-ops-test` green.
- [ ] Milestone 4: ADR-32 adoption contract amended; `okf validate` green.
- [ ] Milestone 4: `docs/user/read-models-and-projections.md`, `keiro/CHANGELOG.md`, and
      `keiro-ops/CHANGELOG.md` updated.
- [ ] Milestone 4: vocabulary reconciliation with plan 248 checked and recorded.
- [ ] Milestone 4: `just verify` green; MasterPlan 39 registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The red library baseline failed only on the two intended zero-row UPDATE symptoms:
  renamed registration shape expected `Just "catalog-counter-query-renamed-v1"` but got
  `Nothing`, and added registration group expected `Just "counter-group"` but got
  `Nothing` (six focused examples, two failures).
- The red ops baseline failed only on the intended v1 asymmetries: scoped preview headers
  expected `name/kind/state/scope/stored/current` but got
  `group/state/stored_slice/current_slice`, and an unknown requested group returned
  `PreviewRequired` with schema `keiro/catalog-adoption-preview/v1` instead of a typed
  refusal (four focused examples, two failures).
- The registry-complete implementation passes all eight focused catalog-adoption examples,
  including rename, add, out-of-scope move protection, and failed stale-format insertion,
  and the full `keiro-test` suite passes 540 examples with zero failures.
- A missing registration inserted while adopting a failed stale-format group cannot be
  marked `live`: doing so would reopen a query model while EP-3 deliberately preserves the
  group's recovery fence. The insertion now mirrors the locked group lifecycle as
  `abandoned` with no `last_built_at`; the focused recovery/adoption test pins that rule.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the preview/execute scope mismatch by *annotating* every row of a
  whole-catalog preview with an explicit scope marker (`adopt` / `skip`) at the operator
  boundary, rather than filtering the preview down to the requested groups.
  Rationale: pure filtering would be truthful about what `--force` executes but would
  hide the other drifted groups entirely, so the operator in the motivating scenario
  would still be ambushed by `RegisteredGroupSliceDrift` at startup — just with less
  information. Annotation keeps the whole-catalog situational awareness the current
  preview provides *and* makes the executed subset unambiguous, and an explicit warning
  names the out-of-scope groups that still block startup. The library-level
  `previewCatalogAdoption` stays whole-catalog ("classify the world"); the scope is a
  property of the operator's request, so it is applied in
  `Keiro.Projection.Catalog.Operations`, which is exactly the operator-neutral boundary
  ADR-28 says keiro-ops must wrap.
  Date: 2026-08-12
- Decision: The scoped preview validates the requested group names against the catalog
  and fails with the same `AdoptGroupNotInCatalog` refusal execution would produce.
  Rationale: "the approved plan and the executed plan are the same plan" includes
  failing the same way; today a typo'd group name previews cleanly and only fails at
  `--force`.
  Date: 2026-08-12
- Decision: Adoption inserts a registration row when the catalog claims a name that has
  no row, instead of reporting it `missing` and deferring to startup self-heal. The
  per-registration outcome vocabulary is therefore `adopted` (existing row updated),
  `inserted` (row created), and `orphaned-old-name` (old row deleted); `missing` never
  occurs as a terminal outcome.
  Rationale: ADR-32 already defines adoption as reconciling "bound query model version,
  shape, and group metadata in one transaction"; leaving a known-needed insert to the
  next startup makes the adoption report untruthful ("adopted" for a row it never
  touched) and leaves a window where the stamped slice and the registry disagree.
  Date: 2026-08-12
- Decision: Adoption deletes an orphaned old-name registry row inside the adoption
  transaction, under a documented three-part rule, rather than merely surfacing it for a
  separate operator decision. The rule: a `keiro.keiro_read_models` row is deleted only
  when (1) the operator ran the two-phase preview, which lists the deletion by name
  before `--force`; (2) the row is bound to a group being adopted in this invocation;
  and (3) no registration anywhere in the validated catalog — in scope or out — claims
  the row's name. Rows whose names are claimed by an out-of-scope group are moves, not
  orphans, and are left untouched.
  Rationale: MasterPlan 41
  (docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md)
  is making read-model registry state an externally observed contract, which cuts both
  ways: deleting an observed row is visible, but a permanently `live` row for a model no
  code writes or serves is a standing lie to every external reader — strictly worse than
  absence. Deletion happens only at the operator-reviewed adoption boundary (a rename is
  always a slice change, so it can only reach the runtime through preview-then-adopt),
  never silently at startup registration. `keiro_read_models` is keiro-owned metadata,
  so the deletion respects ADR-28 schema ownership, and startup registration already
  sets the precedent by deleting orphaned legacy *group* rows.
  Date: 2026-08-12
- Decision: Bump the adoption report envelopes to `keiro/catalog-adoption-preview/v2`
  and `keiro/catalog-adoption-outcome/v2` with no compatibility shim for v1.
  Rationale: 0.12.0.0 is unreleased; MasterPlan 39 assigns this plan ownership of the
  final adoption report shape before the formats become compatibility promises.
  Date: 2026-08-12
- Decision: Do not add a registered-lifecycle-status column to the preview's group rows.
  Rationale: the preview cannot promise lifecycle state at execution time (another
  session may begin a rebuild in between); execution re-checks under `FOR UPDATE` locks
  and refuses with `AdoptGroupNotLive`. A note-level warning for requested groups that
  currently classify as `new` (execution would refuse them as unregistered) gives the
  operator the heads-up without pretending the preview is a fence.
  Date: 2026-08-12
- Decision: This plan owns the operator-visible adoption vocabulary and table format;
  plan 248 (docs/plans/248-give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path.md,
  a soft predecessor, still a skeleton at drafting time) must report its recovery
  outcomes through the same per-group/per-registration vocabulary, and whichever plan
  lands second reconciles.
  Rationale: MasterPlan 39's Integration Points section assigns exactly this split.
  Date: 2026-08-12
- Decision: When adoption inserts a previously missing registration for a failed
  stale-format group, insert it as `abandoned` with no last-built timestamp; insertions
  for live groups remain `live` and are stamped at adoption time.
  Rationale: EP-3 made a failed pre-canonical group deliberately adoptable without
  reopening its fence. A newly inserted `live` registration would contradict that group
  lifecycle and permit query traffic to appear healthy before recovery. Mirroring the
  locked group state keeps catalog acceptance separate from rebuild recovery.
  Date: 2026-08-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

Everything below is stated from scratch; no prior plan is required reading. All paths are
relative to the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

### The subsystem in plain language

A *projection catalog* is a typed, in-code declaration of an application's read side:
event sources, target tables, projections, query models, and *rebuild groups* (named sets
of target tables that are rebuilt together as one unit). `validateProjectionCatalog` in
`keiro/src/Keiro/Projection/Catalog.hs` turns the raw declaration into a
`ValidatedProjectionCatalog`. Each rebuild group has a *group slice fingerprint* — a hash
(text of the form `slice-v2:<hex>`) over exactly the catalog facts that can affect that
group, including each bound query model's registry name, version, and shape hash. Renaming
or adding a query model therefore always changes the owning group's slice.

Two keiro-owned tables persist this state (created by
`keiro-migrations/migrations/0001-keiro-bootstrap.sql` and reshaped by `0022.sql`/`0024.sql`):

- `keiro.keiro_projection_rebuild_groups` — one row per rebuild group: `group_id`,
  `slice_fingerprint`, lifecycle `status` (`live` / `rebuilding` / `failed`), the active
  run id, and audit columns.
- `keiro.keiro_read_models` — the *query registration registry*: one row per query model,
  keyed by `name` (the registry name), with `version`, `shape_hash`,
  `rebuild_group_id`, `status`, and `last_built_at`. MasterPlan 41 is in the process of
  making this registry externally observable by out-of-process SQL consumers, which is why
  its rows must never be silently misleading.

At service startup, `registerProjectionCatalog` (transaction body
`registerProjectionCatalogTx`, `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, around lines
262–340) upserts each group row and compares the stored slice against the catalog's
current slice. A mismatch on a `slice-v2:` stored value is the typed startup error
`RegisteredGroupSliceDrift` (constructed in the `registerGroups` loop around lines
289–295) — the service refuses to run until an operator explicitly *adopts* the change.
The same transaction registers query models: a name with no row is inserted
(`insertQueryRegistrationStmt`, used in the `registerQueries` branch around lines
302–314 — this is why *added* names self-heal at the next startup), and an existing row
is reconciled or refused with typed drift. Nothing at startup ever deletes a
`keiro_read_models` row; only orphaned *legacy group* rows are cleaned
(`deleteOrphanLegacyGroupsStmt`, around lines 923–937).

*Catalog adoption* is the explicit preview-then-adopt evolution API in the same module:

- `previewCatalogAdoption` (around lines 342–380) reads all registered group rows and
  classifies every catalog group as `AdoptionNew`, `AdoptionUnchanged`,
  `AdoptionSliceChanged`, or `AdoptionStaleFormat`, plus lists registered non-legacy
  groups absent from the catalog (`removedGroups`). It returns a `CatalogAdoptionPlan`.
  It takes no group filter: the plan always covers the whole catalog.
- `adoptCatalogGroups` (around lines 382–439) takes a *non-empty set of reviewed group
  ids*, refuses any id not in the catalog (`AdoptGroupNotInCatalog`), then in one
  transaction (`adoptTx`, around lines 404–421) locks every named group `FOR UPDATE`,
  requires each to be registered and `live`, stamps each group's new slice
  (`adoptGroupSliceStmt`), and runs `adoptQueryRegistrationStmt` for each catalog
  registration whose `rebuildGroupId` is in the named set. It returns the adopted
  `[GroupRebuildMetadata]`.

One layer up, `keiro/src/Keiro/Projection/Catalog/Operations.hs` is the operator-neutral
adapter: it wraps the library calls in versioned, JSON-friendly report types —
`CatalogAdoptionReport` (schema `keiro/catalog-adoption-preview/v1`, with per-group
`CatalogAdoptionGroupPreview` rows) and `CatalogAdoptionOutcome` (schema
`keiro/catalog-adoption-outcome/v1`). It contains no parser, renderer, or confirmation
policy.

The operator CLI lives in `keiro-ops/src/Keiro/Ops/Rebuild.hs`. Per ADR-28, every
mutating command has two phases: without `--force` it renders a preview and prints the
exact force invocation; with `--force` it calls the supported mutation. The `Adopt` arm of
`runCommand` (around lines 205–210) is where defect A lives, and `adoptionPreviewResult`
(around lines 286–303) renders the preview table with headers
`["group", "state", "stored_slice", "current_slice"]` plus rows for removed groups and a
fixed note line.

### Defect A: the preview and the execution are different plans

In `keiro-ops/src/Keiro/Ops/Rebuild.hs`:

```haskell
Adopt options
  | env.force ->
      runCatalogAction env (adoptCatalogGroups operations options.groups) (Succeeded . adoptionOutcomeResult)
  | otherwise ->
      runCatalogAction env (Right <$> previewCatalogAdoption operations) $ \report ->
        PreviewRequired (adoptionPreviewResult report) (forceInvocation env (adoptArguments options))
```

The force branch passes `options.groups`; the preview branch cannot — the Operations-level
`previewCatalogAdoption` takes no groups. Concretely: groups A and B both slice-changed;
the operator runs `keiro-ops rebuild adopt A`; the preview table lists A *and* B (and any
`removedGroups`) with no marker distinguishing what the printed force command will
actually adopt; the operator re-runs the suggested command; only A is adopted; the next
startup still fails with `RegisteredGroupSliceDrift` on B, despite an approved preview
that implied full reconciliation. A second, smaller asymmetry: naming a group that is not
in the catalog previews cleanly today and is only refused at `--force`.

### Defect B: UPDATE-only registration reconciliation and stranded old-name rows

`adoptQueryRegistrationStmt` (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, around lines
904–921) is:

```sql
UPDATE keiro.keiro_read_models
SET version = $2, shape_hash = $3, rebuild_group_id = $4, updated_at = now()
WHERE name = $1
```

with a `D.noResult` decoder, so a zero-row match is indistinguishable from success.
`adoptTx` runs it for every in-scope registration and stamps the group slice in the same
transaction regardless. Consequences:

- An *added* query model (catalog claims name Z, no row exists) is silently skipped.
  Startup self-heals it via `insertQueryRegistrationStmt`, but the adoption report
  claimed to have reconciled a registration it never touched.
- A *renamed* query model (row exists under old name X; catalog claims new name Y) is
  doubly wrong: the UPDATE on Y matches nothing, so Y is never created until the next
  startup, and row X remains in `keiro.keiro_read_models` forever — `status = 'live'`,
  bound to the group — for a model no code serves. No supported path ever removes it:
  `deleteOrphanLegacyGroupsStmt` cleans only group rows.

Note the containment property that makes deletion safe to scope: a rename is a
query-registration fact, so it always changes the group slice, so it can only reach a
running system through the operator-reviewed preview-then-adopt flow. And a row whose name
the catalog claims under a *different* group is a query-model *move*, not an orphan;
ADR-32 requires moves to be reviewed across every affected group, and ordinary
registration keeps exposing a half-adopted move as drift.

### Relevant ADRs and coordination context

- docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md
  (ADR-32) defines canonical fingerprints, slice-scoped lifecycle identity, and the
  adoption contract this plan amends: "Adoption accepts a non-empty set of reviewed group
  IDs … then updates group slices and reconciles bound query model version, shape, and
  group metadata in one transaction", and describes the keiro-ops command's two phases.
  Milestone 4 amends both paragraphs.
- docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md
  (ADR-28) requires every operator command to wrap an exported library operation, defines
  the preview/`--force` two-phase discipline, and pins schema ownership.
  `keiro.keiro_read_models` is keiro-owned, so adoption may reconcile and delete its rows;
  this plan adds no ad hoc SQL outside the owning library module.
- docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md
  (ADR-26) defines the four catalog identities; useful background, not amended here.
- MasterPlan 39 Integration Points: this plan (EP-4) owns the final adoption
  preview/result types and the keiro-ops table format; plan 248 (EP-3, recovery for
  `'$pre-canonical'` runs, a soft predecessor that is still an unfilled skeleton as of
  2026-08-12) must report through the same vocabulary, and whichever lands second
  reconciles. Before starting Milestone 3, read plan 248's file and `git log` for its
  commits; if it has landed changes to `previewCatalogAdoption`, `adoptTx`, or the
  keiro-ops rendering, rebase this plan's type shapes on top and record the
  reconciliation in the Decision Log.
- MasterPlan 41
  (docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md)
  makes read-model registry state an external contract; it motivates the documented
  orphan-deletion rule in the Decision Log. No cross-repository ADR bears on this work.

### Tests and fixtures you will extend

Database-backed tests use the suite-level template-database fixture from
`keiro-test-support` (`Keiro.Test.Postgres`): `withMigratedSuite` /
`withMigratedSuiteWith` start one ephemeral PostgreSQL server per suite, migrate a
template database once, and clone a fresh database per example via
`around (withFreshStore fixture)`. Never add per-example migrations.

- `keiro/test/CatalogEvolutionSpec.hs` — the adoption library tests (suite `keiro-test`,
  wired in `keiro/test/Main.hs`). It builds catalogs from `keiro/test/CatalogSpec.hs`
  exports (`validCatalog`, `mainGroupId` = `counter-group`, query models
  `catalog-counter-query` and `catalog-audit-query`, both bound to `mainGroupId`), makes
  targets rebuildable with a local `rebuildableCatalog`, mutates catalogs by mapping over
  `SomeQueryModelBinding` (see its `bumpQueryModel`), seeds application tables with
  `catalogFixtureSql`, and asserts registry state with `lookupReadModel` from
  `Keiro.ReadModel` (returns `Maybe ReadModelMetadata` with `version`, `shapeHash`,
  `rebuildGroupId`, `status`).
- `keiro-ops/test/Main.hs` — suite `keiro-ops-test`; its "catalog rebuild adoption"
  describe block (around lines 142–199) drives `OpsRebuild.runCommand` directly against a
  fresh store with the single-group builder `opsCatalog` (group `ops-group`, table
  `app.ops_catalog`, codec fingerprint parameter) and asserts on the `OpsOutcome` /
  `OpsResult` values (`PreviewRequired result invocation`, `result.headers`,
  `result.rows`, `renderHuman`).


## Plan of Work

The work is four milestones: reproduce, fix the library, fix the operator surface,
document the contract. Each is independently verifiable.

### Milestone 1: reproduce both defects with failing tests

Scope: write database-backed tests that assert the *desired* behavior using only
constructs that compile against the current code, watch them fail for the reasons the
defects predict, and keep them in the working tree to be committed alongside the fixes in
Milestones 2 and 3. At the end of this milestone `cabal test keiro-test` and
`cabal test keiro-ops-test` each fail on exactly the new examples, and the failure
messages match the defect mechanisms.

In `keiro/test/CatalogEvolutionSpec.hs`, inside the existing
`describe "catalog evolution adoption"` block, add two examples (defect B):

First, "adopts a renamed query registration completely". Follow the shape of the existing
first example: seed `catalogFixtureSql`, validate
`current = rebuildableCatalog Catalog.validCatalog`, and register it. Build a renamed
catalog with a local helper modeled on `bumpQueryModel`:

```haskell
renamedCatalog :: ProjectionCatalog
renamedCatalog =
  (rebuildableCatalog Catalog.validCatalog)
    { queryModels = renameCounterQuery <$> rebuildableCatalog Catalog.validCatalog ^. #queryModels
    }

renameCounterQuery :: SomeQueryModelBinding -> SomeQueryModelBinding
renameCounterQuery (SomeQueryModelBinding binding)
  | binding ^. #readModel . #name == "catalog-counter-query" =
      SomeQueryModelBinding
        ( binding
            & #readModel . #name .~ "catalog-counter-query-renamed"
            & #readModel . #shapeHash .~ "catalog-counter-query-renamed-v1"
        )
  | otherwise = SomeQueryModelBinding binding
```

(The registry name is the `ReadModel`'s `name` field; renaming it changes the group slice,
so drift is guaranteed.) Assert, in order: registering the renamed catalog is refused with
`RegisteredGroupSliceDrift` for `Catalog.mainGroupId` (sanity — passes today);
`adoptCatalogGroups renamed (Catalog.mainGroupId :| [])` succeeds; then the two red
assertions —

```haskell
renamedRow <- expectStore store (lookupReadModel "catalog-counter-query-renamed")
renamedRow ^? _Just . #shapeHash `shouldBe` Just "catalog-counter-query-renamed-v1"
oldRow <- expectStore store (lookupReadModel "catalog-counter-query")
oldRow `shouldBe` Nothing
```

Today the first returns `Nothing` (the UPDATE matched zero rows — the silent no-op) and
the second returns a `live` row (the stranded old name). Finish with
`registerProjectionCatalog renamed` returning `Right` (end-state proof).

Second, "inserts an added query registration during adoption". Register
`rebuildableCatalog Catalog.validCatalog`; build an added catalog whose `queryModels`
list gains a third binding on `mainGroupId` observing `Catalog.counterTargetId`, with
registry name `catalog-added-query`, version 1, shape `catalog-added-query-v1`, and a
fresh `mkQueryModelId "added-query"` / `mkClaimSite "catalog:added-query"` identity. The
simplest construction is to export `counterBinding` from `keiro/test/CatalogSpec.hs`
(add it to the module export list) and derive the new binding by lens updates on
`queryModelId`, `readModel . #name`, `readModel . #shapeHash`, `observedTargets`, and
`claimSite`. Adopt `mainGroupId` with the added catalog and assert (red)
`lookupReadModel "catalog-added-query"` is a `Just` row bound to the group. Today it is
`Nothing`.

In `keiro-ops/test/Main.hs` (defect A), first generalize the fixture: add a two-group
builder `opsCatalogPair :: Text -> Text -> Catalog.ProjectionCatalog` alongside
`opsCatalog`, whose second group `ops-group-b` mirrors the first with its own source
(`ops-source-b`, category `ops-catalog-b`), target (`ops-target-b`, table
`app.ops_catalog_b`), projection set, and codec fingerprint parameter. Extend the
example's fixture SQL to also create `app.ops_catalog_b`. Then add two examples to the
"catalog rebuild adoption" describe block:

First, "annotates preview scope and warns about out-of-scope drift". Register
`opsCatalogPair "a-v1" "b-v1"`, build operations for `opsCatalogPair "a-v2" "b-v2"` (both
groups slice-changed), and run the non-forced
`OpsRebuild.Adopt (OpsRebuild.AdoptOptions (NonEmpty.singleton opsGroupId))`. Red
assertions: the preview result's `headers` are
`["name", "kind", "state", "scope", "stored", "current"]`; the row whose name is
`ops-group` has scope `adopt`; the row whose name is `ops-group-b` has scope `skip`; and
`renderHuman result` contains both `out-of-scope` and `ops-group-b`. Today the headers
are the four-column v1 shape, so every assertion fails.

Second, "refuses a preview for a group the catalog does not contain". Run the non-forced
`Adopt` naming a syntactically valid but unknown group (`ops-group-missing`). Red
assertion: the outcome is `Failed` with a message mentioning `AdoptGroupNotInCatalog`.
Today it is `PreviewRequired` over the whole catalog.

Run both suites, confirm each new example fails with the predicted message, and paste
short failure excerpts into Surprises & Discoveries. Do not commit yet; these tests are
committed with the fixes so the branch never carries a standalone red commit.

### Milestone 2: make adoption registry-complete in the library (fixes defect B)

Scope: all edits in `keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, its facade
`keiro/src/Keiro/ReadModel/Rebuild.hs`, and the keiro test suite. At the end, adoption
detects and repairs missing rows, deletes proven orphans, and reports per-registration
outcomes; the Milestone-1 keiro-test examples pass; every pre-existing keiro-test example
still passes.

Add the vocabulary types to `Group.hs` (exported from both the module and the
`Keiro.ReadModel.Rebuild` facade):

```haskell
-- | What adoption did (or, in a preview, will do) for one catalog registration.
data RegistrationAdoptionAction
  = RegistrationUpdate -- ^ a row with this name exists; version/shape/group are updated
  | RegistrationInsert -- ^ no row with this name exists; adoption inserts it
  deriving stock (Eq, Show, Generic)

data RegistrationAdoption = RegistrationAdoption
  { registryName :: !Text,
    rebuildGroupId :: !RebuildGroupId,
    action :: !RegistrationAdoptionAction
  }
  deriving stock (Eq, Show, Generic)

-- | A keiro_read_models row bound to a catalog group whose name no registration
-- in the entire validated catalog claims. Adoption deletes in-scope orphans.
data OrphanedRegistration = OrphanedRegistration
  { registryName :: !Text,
    boundGroupId :: !RebuildGroupId
  }
  deriving stock (Eq, Show, Generic)
```

Extend `CatalogAdoptionPlan` with `registrations :: ![RegistrationAdoption]` (planned
action per catalog registration, whole catalog, sorted by name) and
`orphanedRegistrations :: ![OrphanedRegistration]` (sorted by name). Replace the result
of `adoptCatalogGroups` with:

```haskell
data CatalogAdoptionResult = CatalogAdoptionResult
  { adoptedGroups :: ![GroupRebuildMetadata],
    registrationOutcomes :: ![RegistrationAdoption],
    removedOrphans :: ![OrphanedRegistration]
  }
  deriving stock (Eq, Show, Generic)

adoptCatalogGroups ::
  (Store :> es) =>
  ValidatedProjectionCatalog ->
  NonEmpty.NonEmpty RebuildGroupId ->
  Eff es (Either CatalogAdoptionError CatalogAdoptionResult)
```

Rework `adoptTx`. After the existing `lockAll` and the `adoptGroupSliceStmt` loop, replace
the blind `for_ registrations` UPDATE loop with a per-registration disposition pass over
the same sorted in-scope `registrations` list: `Tx.statement name
lookupQueryRegistrationStmt` (it already locks `FOR UPDATE`); on `Just _`, run
`adoptQueryRegistrationStmt` and record `RegistrationUpdate`; on `Nothing`, run the
existing `insertQueryRegistrationStmt` with `queryRegistrationParams` and record
`RegistrationInsert`. Change `adoptQueryRegistrationStmt`'s decoder from `D.noResult` to
`D.rowsAffected` and make the caller check the count is exactly 1 — after a `FOR UPDATE`
lookup in the same transaction, anything else is an invariant violation; fail loudly with
`error "adoptTx: locked registration row vanished"` in the established style of this
module's impossible-state errors. Then run the orphan pass: a new statement

```haskell
lockGroupRegistrationsStmt :: Statement [Text] [(Text, Text)]
-- SELECT name, rebuild_group_id FROM keiro.keiro_read_models
-- WHERE rebuild_group_id = ANY($1) ORDER BY name FOR UPDATE
```

over the adopted group ids, filtered to names not present in the set of *all* catalog
registration names (`catalogRegistrations catalog`, the whole catalog — this is what
protects moves to out-of-scope groups and unmanaged legacy rows, which are bound to
`$legacy-read-model:` groups the catalog never declares). Delete the survivors with

```haskell
deleteQueryRegistrationsStmt :: Statement [Text] ()
-- DELETE FROM keiro.keiro_read_models WHERE name = ANY($1)
```

(skip the statement entirely when the orphan list is empty), and record them as
`removedOrphans`. Run this pass after the disposition loop so it observes final bindings.
Build the returned `CatalogAdoptionResult` from the re-read group metadata (existing
`lookupGroupStmt` traversal), the recorded dispositions, and the orphan list.

Extend `previewCatalogAdoption` in the same file: inside its existing transaction, read
the registry once with a new read-only statement

```haskell
listQueryRegistrationBindingsStmt :: Statement () [(Text, Text)]
-- SELECT name, rebuild_group_id FROM keiro.keiro_read_models ORDER BY name
```

and derive `registrations` (for every catalog registration: `RegistrationUpdate` if its
name appears in the rows, else `RegistrationInsert`) and `orphanedRegistrations` (rows
whose `rebuild_group_id` parses to a catalog-declared group id and whose name is claimed
by no catalog registration). Group classification is unchanged.

Update the two existing call-site families in the keiro suite:
`keiro/test/CatalogEvolutionSpec.hs` examples that bind `adoptCatalogGroups` results now
destructure `CatalogAdoptionResult` (e.g. the slice-v1 example's discarded binding needs
no change beyond the type; the first example reads the Operations outcome and is updated
in Milestone 3 — temporarily adjust only what the compiler requires). Extend the two
Milestone-1 examples with the now-expressible assertions: the rename example asserts
`registrationOutcomes` contains `catalog-counter-query-renamed` with
`RegistrationInsert`, `removedOrphans` contains `catalog-counter-query` bound to
`Catalog.mainGroupId`, and a pre-adoption `previewCatalogAdoption renamed` plan lists the
same pending insert and orphan; the added-model example asserts `RegistrationInsert` for
`catalog-added-query` and empty `removedOrphans`. Also add one guard example: a
query-model *move* — bind `catalog-audit-query` to `Catalog.additiveGroupId` in an
`additiveCatalog`-based variant, adopt only `mainGroupId`, and assert the audit row still
exists (it is not an orphan because the whole catalog claims its name).

Acceptance: `cabal build all` compiles; `cabal test keiro-test` is green, including the
Milestone-1 examples now extended; `cabal test keiro-ops-test` may be red only on the
Milestone-1 ops examples (defect A is still unfixed) plus any compile fallout in
`keiro-ops/src/Keiro/Ops/Rebuild.hs`, which you should patch minimally in this milestone
(adapt `adoptionOutcomeResult` to the new result type without redesigning the table —
that is Milestone 3's job). Commit Milestones 1+2's keiro-side work together.

### Milestone 3: make the operator preview scoped and truthful (fixes defect A)

Scope: `keiro/src/Keiro/Projection/Catalog/Operations.hs`,
`keiro-ops/src/Keiro/Ops/Rebuild.hs`, and `keiro-ops/test/Main.hs`. At the end, the
non-forced `rebuild adopt GROUP...` preview is scope-annotated, warns about out-of-scope
drift, refuses unknown groups exactly as execution does, and the forced outcome reports
per-registration results; all suites green.

In `Operations.hs`:

- `CatalogAdoptionGroupPreview` gains `inScope :: !Bool`.
- New preview row types mirroring the library vocabulary:
  `CatalogAdoptionRegistrationPreview { registryName :: !Text, rebuildGroupId ::
  !RebuildGroupId, action :: !RegistrationAdoptionAction, inScope :: !Bool }` and
  `CatalogAdoptionOrphanPreview { registryName :: !Text, boundGroupId ::
  !RebuildGroupId, inScope :: !Bool }`.
- `CatalogAdoptionReport` gains `requestedGroups :: ![RebuildGroupId]`,
  `registrations :: ![CatalogAdoptionRegistrationPreview]`,
  `orphanedRegistrations :: ![CatalogAdoptionOrphanPreview]`, and
  `outOfScopeChangedGroups :: ![RebuildGroupId]` (catalog groups classified
  `AdoptionSliceChanged` or `AdoptionStaleFormat` that are not requested — the exact set
  that will still fail startup registration after this adoption). `reportSchema` becomes
  `"keiro/catalog-adoption-preview/v2"`.
- `previewCatalogAdoption` changes signature to

  ```haskell
  previewCatalogAdoption ::
    (Store :> es) =>
    ProjectionCatalogOperations ->
    NonEmpty RebuildGroupId ->
    Eff es (Either CatalogOpsError CatalogAdoptionReport)
  ```

  It first validates every requested id against the catalog's group set and returns
  `Left (CatalogOpsAdoptionRefused (AdoptGroupNotInCatalog groupId))` on the first
  failure — the same refusal, same order (sorted, deduplicated), as
  `adoptCatalogGroups`. Then it calls the library preview and annotates scope: a group,
  registration, or orphan is in scope when its (bound) group id is in the requested set.
- `CatalogAdoptionOutcome` gains `registrationOutcomes :: ![RegistrationAdoption]` and
  `removedOrphans :: ![OrphanedRegistration]`; `reportSchema` becomes
  `"keiro/catalog-adoption-outcome/v2"`. `adoptCatalogGroups` maps the new library
  result.
- Extend the `ToJSON` instances: group values gain `"inScope"`; the report gains
  `"requestedGroups"`, `"registrations"` (objects with `"name"`, `"groupId"`,
  `"action"` of `"update"`/`"insert"`, `"inScope"`), `"orphanedRegistrations"` (objects
  with `"name"`, `"groupId"`, `"inScope"`), and `"outOfScopeChangedGroups"`; the outcome
  gains `"registrationOutcomes"` (with `"outcome"` of `"adopted"`/`"inserted"`) and
  `"removedOrphans"`.

In `keiro-ops/src/Keiro/Ops/Rebuild.hs`:

- The non-forced `Adopt` branch becomes
  `runCatalogAction env (previewCatalogAdoption operations options.groups) $ \report -> …`
  (drop the `Right <$>` wrapper; `runCatalogAction` already surfaces `Left` as `Failed`).
- `adoptionPreviewResult` renders one table with headers
  `["name", "kind", "state", "scope", "stored", "current"]`:
  catalog-group rows (`kind` `group`, `state` from the existing classification words plus
  `removed` for `removedGroups`, `scope` `adopt`/`skip`, stored/current slices as today);
  registration rows (`kind` `registration`, `state` `update`/`insert`, empty
  stored/current); orphan rows (`kind` `registration`, `state` `orphaned-old-name`,
  `stored` showing the bound group id). Keep the existing metadata note row. Append a
  warning note row when `outOfScopeChangedGroups` is non-empty:
  `"warning: out-of-scope groups still drift and will fail startup registration until
  adopted: <comma-separated ids>"`, and another when any requested group classifies
  `AdoptionNew`:
  `"warning: requested groups not yet registered; --force will refuse: <ids>"`.
- `adoptionOutcomeResult` renders headers `["name", "kind", "outcome", "detail"]`:
  group rows (`kind` `group`, `outcome` from `lifecycleStatusText`, `detail` the slice
  fingerprint); registration rows (`kind` `registration`, `outcome`
  `adopted`/`inserted`, `detail` the group id); orphan rows (`kind` `registration`,
  `outcome` `orphaned-old-name`, `detail` the former group id).

In `keiro-ops/test/Main.hs`, update the pre-existing adoption example to the new headers
and row shapes (its force-phase assertion becomes
`["ops-group", "group", "live", <slice>]`-shaped), keep its
end-to-end register-then-rebuild proof, and finish the Milestone-1 examples: the scoped
preview example additionally asserts the JSON value carries
`"outOfScopeChangedGroups" == ["ops-group-b"]`, and add one force-phase example for the
rename flow at the ops level if not already covered by the keiro suite (optional —
library coverage in Milestone 2 is authoritative; do not duplicate heavy scenarios).

Acceptance: `cabal build all`; `cabal test keiro-ops-test` and `cabal test keiro-test`
both green. Commit with the Milestone-1 ops tests.

### Milestone 4: amend the contract documents and run the full gate

Scope: documentation, changelogs, ADR, reconciliation, and the repository gate.

Amend docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md
in the Decision section: rewrite the adoption paragraph to state that adoption reconciles
each in-scope registration by update-or-insert, reports a per-registration outcome
(`adopted` / `inserted` / `orphaned-old-name`), and deletes an old-name registry row only
under the three-part rule (previewed by name; bound to an adopted group; unclaimed by any
registration in the entire catalog), with the MasterPlan-41 external-observability
rationale; rewrite the keiro-ops paragraph to state that the non-forced preview is
whole-catalog but scope-annotated against the named groups, warns when out-of-scope
groups still drift, and refuses group ids the catalog does not contain exactly as
`--force` would. Update the frontmatter `timestamp` to the amendment time (keep `docId`
ADR-32 and `date` unchanged), append the change to the bundle's reserved log with
`okf log add`, and run the strict profile check (commands in Concrete Steps).

Update `docs/user/read-models-and-projections.md`: the "Catalog evolution is explicit"
paragraph gains the update-or-insert, per-registration outcome, and orphan-deletion rule;
the operations envelope list swaps in `keiro/catalog-adoption-preview/v2` and
`keiro/catalog-adoption-outcome/v2`; the keiro-ops paragraph mentions scope annotation.

Update `keiro/CHANGELOG.md` Unreleased: under `### Fixed`, the silent zero-row
registration no-op and the stranded renamed-registration row; under
`### Breaking Changes`, the `adoptCatalogGroups` result type
(`CatalogAdoptionResult`) and the extended `CatalogAdoptionPlan`. Update
`keiro-ops/CHANGELOG.md` Unreleased: under `### Fixed`, the preview/execute scope
mismatch; under `### Changed`, the new preview/outcome tables and v2 JSON envelopes and
the preview-time `AdoptGroupNotInCatalog` refusal.

Reconcile with plan 248: re-read
docs/plans/248-give-pre-canonical-in-flight-rebuild-runs-a-supported-recovery-path.md and
its landed commits (if any). If it landed first, verify its recovery reporting uses this
plan's vocabulary and table conventions and adapt whichever side is cheaper, recording
the outcome in both plans' Decision Logs; if it has not landed, record here that 248 must
consume `RegistrationAdoptionAction` / per-group outcome vocabulary as defined by this
plan. Update the MasterPlan 39 Exec-Plan Registry row for EP-4 and its Progress section
as milestones complete (that edit is part of implementation, not drafting).

Finish with the full repository gate `just verify` from the repository root, then write
the Outcomes & Retrospective entry and perform the ADR distillation pass (the durable
context here is the orphan-deletion rule and scope-annotation contract — both land in
ADR-32; nothing else in this plan is durable beyond the code).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
stated otherwise. The database-backed suites provision their own ephemeral PostgreSQL;
no manual database setup is needed.

Milestone 1 (red):

```bash
cabal build all
cabal test keiro-test --test-show-details=direct
cabal test keiro-ops-test --test-show-details=direct
```

Expected: compilation succeeds; `keiro-test` reports exactly the two new adoption
examples failing, with output shaped like

```text
  1) catalog evolution adoption adopts a renamed query registration completely
       expected: Just "catalog-counter-query-renamed-v1"
        but got: Nothing
```

and `keiro-ops-test` reports the two new preview examples failing on the header/scope
assertions. Any other failure means a step above was misapplied — stop and fix before
proceeding.

Milestones 2 and 3 (green), after each milestone's edits:

```bash
cabal build all
cabal test keiro-test --test-show-details=direct
cabal test keiro-ops-test --test-show-details=direct
```

Expected: `0 failures` in both suites.

Milestone 4 (contract and gate):

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf log add docs/adr   # follow the prompt/flags convention used by prior ADR edits
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just verify
```

Expected: `okf validate` exits zero; `just verify` (build, all test suites, ADR/OKF and
policy checks) exits zero.

Commit and trailer convention: use Conventional Commits (`test(rebuild): …`,
`fix(rebuild): …`, `fix(ops): …`, `docs(adr): …`) and include on every commit the
trailers:

```text
MasterPlan: docs/masterplans/39-fix-the-catalog-rebuild-replay-and-adoption-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/249-make-catalog-adoption-scoped-truthful-and-registry-complete.md
Intention: intention_01kzw6dk7qe1qayx2qdz6vcqfd
```

Suggested commit sequence: one commit for Milestones 1+2 (keiro library fix with its red
tests turned green), one for Milestone 3 (ops surface with its tests), one for
Milestone 4 (docs/ADR/changelogs). Commit directly to the current branch; do not create a
feature branch.


## Validation and Acceptance

Acceptance is behavioral. After the change:

1. Renamed registration (library): with a registered catalog whose `counter-group` binds
   `catalog-counter-query`, adopting a catalog that renames it to
   `catalog-counter-query-renamed` leaves `keiro.keiro_read_models` with exactly one row
   for the model — the new name, `live`, bound to `counter-group` — and no row under the
   old name; the `CatalogAdoptionResult` lists the new name under `registrationOutcomes`
   with the insert action and the old name under `removedOrphans`. The same scenario run
   before the fix leaves the old row `live` and creates nothing. Proven by
   `cabal test keiro-test` (failing before, passing after).
2. Added registration (library): adopting a catalog that adds `catalog-added-query` to a
   registered group creates its registry row inside the adoption transaction and reports
   it inserted. Proven by the same suite.
3. Moves are protected: adopting only `counter-group` when the catalog moved
   `catalog-audit-query` to another group deletes nothing.
4. Scoped preview (operator): with two registered groups both slice-changed, running the
   embedded command without force for one group produces a `PreviewRequired` whose table
   is, schematically:

   ```text
   name          kind          state              scope  stored        current
   ------------  ------------  -----------------  -----  ------------  ------------
   ops-group     group         slice-changed      adopt  slice-v2:...  slice-v2:...
   ops-group-b   group         slice-changed      skip   slice-v2:...  slice-v2:...
   note          adoption changes only keiro-owned registration metadata; ...
   note          warning: out-of-scope groups still drift and will fail startup
                 registration until adopted: ops-group-b
   ```

   and whose JSON carries `"schema": "keiro/catalog-adoption-preview/v2"`,
   per-row `"inScope"`, and `"outOfScopeChangedGroups": ["ops-group-b"]`. Proven by
   `cabal test keiro-ops-test` (failing before, passing after).
5. Preview mirrors execution: the non-forced command naming a group absent from the
   catalog fails with `AdoptGroupNotInCatalog` instead of rendering a preview.
6. Truthful outcome: the forced command's result table reports each group row and each
   registration with `adopted` / `inserted` / `orphaned-old-name`, and its JSON carries
   `"schema": "keiro/catalog-adoption-outcome/v2"`.
7. End-to-end: after adopting the in-scope group, `registerProjectionCatalog` with the
   new catalog succeeds for that group's slice and a rebuild can begin — preserved by the
   existing keiro-ops adoption example's final `beginGroupRebuild` proof.
8. The whole repository gate `just verify` passes, which includes ADR strict validation
   for the amended ADR-32.

Interpreting results: hspec prints `N examples, 0 failures` per suite on success; any
`expectation failed` naming an example added by this plan means the corresponding
milestone is incomplete.


## Idempotence and Recovery

Every step is safe to repeat. The test suites clone a fresh database per example from the
suite template, so re-running them cannot accumulate state. Adoption itself remains
idempotent at the new granularity: re-running `--force` for an already-adopted group is
the existing successful no-op (`AdoptionUnchanged` classification; registration
dispositions all become `RegistrationUpdate` with identical values; the orphan list is
empty on the second run because the first run deleted the only orphans). The registry
deletion is inside the same transaction as the slice stamp and registration updates, so
an interrupted adoption leaves either the complete old state or the complete new state,
never a half-reconciled registry. If a milestone's edits go wrong, `git checkout --`
the touched files and re-apply; no migration or persistent format changes in this plan
(the report *envelopes* change, but they are wire shapes, not stored data — no prefix
bump under ADR-32's rules is required, and none is taken).


## Interfaces and Dependencies

No new packages. Everything uses libraries already in the build plan: `hasql` statements
with `Hasql.Decoders.rowsAffected` (already used across `keiro/src/Keiro/Projection.hs`
and others), `hasql-transaction`, `effectful`, `aeson`, `hspec`, and the
`keiro-test-support` fixture (`Keiro.Test.Postgres`).

At the end of Milestone 2, `keiro/src/Keiro/ReadModel/Rebuild/Group.hs` (re-exported via
`keiro/src/Keiro/ReadModel/Rebuild.hs`) must provide:

```haskell
data RegistrationAdoptionAction = RegistrationUpdate | RegistrationInsert
data RegistrationAdoption =
  RegistrationAdoption { registryName :: !Text, rebuildGroupId :: !RebuildGroupId,
                         action :: !RegistrationAdoptionAction }
data OrphanedRegistration =
  OrphanedRegistration { registryName :: !Text, boundGroupId :: !RebuildGroupId }
data CatalogAdoptionPlan =
  CatalogAdoptionPlan { groupStates :: ![(RebuildGroupId, GroupAdoptionClass)],
                        removedGroups :: ![RebuildGroupId],
                        registrations :: ![RegistrationAdoption],
                        orphanedRegistrations :: ![OrphanedRegistration] }
data CatalogAdoptionResult =
  CatalogAdoptionResult { adoptedGroups :: ![GroupRebuildMetadata],
                          registrationOutcomes :: ![RegistrationAdoption],
                          removedOrphans :: ![OrphanedRegistration] }

previewCatalogAdoption ::
  (Store :> es) => ValidatedProjectionCatalog -> Eff es CatalogAdoptionPlan
adoptCatalogGroups ::
  (Store :> es) => ValidatedProjectionCatalog -> NonEmpty RebuildGroupId ->
  Eff es (Either CatalogAdoptionError CatalogAdoptionResult)
```

At the end of Milestone 3, `keiro/src/Keiro/Projection/Catalog/Operations.hs` must
provide (in addition to the enriched report/outcome records described in the milestone):

```haskell
previewCatalogAdoption ::
  (Store :> es) => ProjectionCatalogOperations -> NonEmpty RebuildGroupId ->
  Eff es (Either CatalogOpsError CatalogAdoptionReport)
adoptCatalogGroups ::
  (Store :> es) => ProjectionCatalogOperations -> NonEmpty RebuildGroupId ->
  Eff es (Either CatalogOpsError CatalogAdoptionOutcome)
```

with `reportSchema` values `keiro/catalog-adoption-preview/v2` and
`keiro/catalog-adoption-outcome/v2`, and `keiro-ops/src/Keiro/Ops/Rebuild.hs` must render
them through the six-column preview table and four-column outcome table defined in
Milestone 3. `AdoptOptions`, the command parser, and `isMutation` are unchanged.
