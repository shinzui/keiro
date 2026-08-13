---
id: 257
slug: add-targeted-per-stream-reprojection-to-catalog-operations
title: "Add targeted per-stream reprojection to catalog operations"
kind: exec-plan
created_at: 2026-08-12T23:55:46Z
intention: "intention_01kzw6dkhje7qvw6w321pwyv12"
master_plan: "docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md"
---

# Add targeted per-stream reprojection to catalog operations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, when a projection bug corrupts one aggregate's row in a read-model table, the only
supported repair is a full catalog group rebuild: the whole group leaves live service, every
`ClearBeforeReplay` table is truncated, all of history replays, and every reader — in-process
and out-of-process — loses the model for the duration. The blast radius of a one-row bug is
the entire table and every consumer of it.

After this plan, an operator can run "reproject aggregate X into model M" instead. For a
read model whose table holds one row (or one row-set) per aggregate stream — a
*row-per-aggregate* model — the operator deletes exactly that aggregate's rows and replays
exactly that aggregate's events, in one database transaction, while the rebuild group stays
in live service the whole time. No group-wide fence is taken: `runQuery` keeps answering,
concurrent commands for other aggregates keep committing, async projections keep applying,
and an out-of-process SQL reader never observes a truncated or partially replayed table —
it sees the old rows for stream X until the repair commits, and the repaired rows after.

Concretely, after this plan an operator with an embedded `keiro-ops` binary runs:

```text
$ my-service-ops rebuild reproject order-rows-projection orders-42 --force
projection             group            stream    stream_version rows_cleared events_read events_applied
order-rows-projection  order-reporting  orders-42 7              1            7           7
```

and can verify with `SELECT` that only the `orders-42` row changed, that every other row is
byte-identical (unchanged `xmin`), and that `keiro.keiro_projection_rebuild_groups` still
says `live` with no active run.

This is capability 4 of
`docs/improvement-requests/make-read-models-safely-readable-by-out-of-process-consumers.md`
(IR-22), coordinated by
`docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md`.
It is not a substitute for full rebuilds — a table shape change or a catalog slice change
still needs one — but it removes the most common reason for one.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `StreamScopedRows` declaration, `ReplayableStreamScoped` replay-policy constructor,
      `declareStreamScopedRows` combinator, `streamScopedRows` inventory field, and the
      `catalogStreamReprojection` accessor added to `keiro/src/Keiro/Projection/Catalog.hs`;
      all pattern-match sites updated; renderer and operations JSON extended.
- [ ] M1: Pure tests proving validation behavior and fingerprint neutrality (toggling the
      declaration changes neither the catalog fingerprint nor the group slice fingerprint)
      pass in `cabal test keiro-test`.
- [ ] M2: New internal module `keiro/src/Keiro/ReadModel/Rebuild/Reproject.hs` implementing
      `reprojectStream` as one `ReadCommitted` transaction (group `FOR UPDATE` lock, stream
      existence/visibility checks, captured stream version, delete-then-replay), re-exported
      through `Keiro.ReadModel.Rebuild`.
- [ ] M2: New DB test module `keiro/test/StreamReprojectSpec.hs` (template-database fixture)
      covering the happy path, byte-stability of other rows, group liveness, dedup and
      checkpoint non-interaction, and every typed refusal; wired into `keiro/test/Main.hs`.
- [ ] M3: `previewStreamReprojection` and `runStreamReprojection` operator wrappers with
      versioned JSON envelopes in `keiro/src/Keiro/Projection/Catalog/Operations.hs`;
      `CatalogOpsError` extended; tests in `keiro/test/CatalogOperationsSpec.hs`.
- [ ] M4: `keiro-ops rebuild reproject PROJECTION STREAM` command (two-phase force policy)
      in `keiro-ops/src/Keiro/Ops/Rebuild.hs` with a transcript-style test in
      `keiro-ops/test/Main.hs`.
- [ ] M5: Documentation section in `docs/user/read-models-and-projections.md`; amendments to
      `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
      and
      `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`
      with strict OKF validation; `Unreleased` changelog entries for `keiro` and `keiro-ops`.
- [ ] Final: `just verify` green; Outcomes & Retrospective written; ADR distillation pass done.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: The row-per-aggregate property is declared per projection, not per target, as a
  new `ProjectionReplayPolicy` constructor `ReplayableStreamScoped` carrying the existing
  replay adapter plus a `StreamScopedRows` record.
  Rationale: the unit that replays is the projection (its adapter receives whole events and
  writes wherever it writes), so a partial per-target declaration could never make the
  operation sound — every owned target must hold the property or none usefully does. A new
  constructor is also the only purely additive shape: `ProjectionCatalog`,
  `ProjectionDefinition`, and `ReplayAdapter` are all constructed positionally by
  `jitsurei/src/Jitsurei/ReadModels.hs` and by keiro-dsl's generated
  `ProjectionCatalog` modules (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits
  `Catalog.ProjectionCatalog` applied to seven list arguments and
  `Catalog.ReplayAdapter Holes.<decode> Holes.<apply>` applied to two), so adding a field to
  any of those records would break every consumer including the committed conformance corpus.
  Date: 2026-08-12
- Decision: The declaration is excluded from the catalog fingerprint and the group slice
  fingerprint. `InventoryProjection` gains a `streamScopedRows :: Bool` field that is
  rendered in reports and operations JSON but deliberately not added to `projectionPreimage`.
  Rationale: mirrors the derived-supplier precedent in
  `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md` —
  the declaration changes no preparation, writer, query-binding, replay, or verification
  fact, so enabling a repair capability must not strand registered groups behind a
  preview-and-adopt ceremony or interact with the slice-preimage extensions that sibling
  plans EP-2/EP-3 of MasterPlan 41 may make. A fingerprint-neutrality test makes the
  exclusion an executed fact rather than an accident.
  Date: 2026-08-12
- Decision: The operation is one `ReadCommitted` transaction that first takes `FOR UPDATE`
  on the group's registration row, then reads the stream's events *inside* the transaction
  through kiroku-store's exported statement `Kiroku.Store.SQL.readStreamForwardStmt`.
  Rationale: every catalog writer (inline command transactions and async appliers) holds
  `FOR SHARE` on the same row inside the same transaction as its target writes, so
  `FOR UPDATE` linearizes the repair against all of them without any lifecycle status
  change; and because `Kiroku.Store.Transaction.runTransaction` runs at `ReadCommitted`
  (verified in `Kiroku.Store.Effect.runTxOnPool`), every statement issued after the lock is
  granted sees everything committed before the grant. Reading the stream *before* the
  transaction would leave a window in which a concurrent writer commits an event plus its
  row write between our read and our lock, and the delete-then-replay would silently lose
  that update. Executing another library's *exported* statement is the established
  ADR-28-compliant pattern — `Keiro.ReadModel.Rebuild` already executes
  `Kiroku.Store.SQL.visibleGlobalHeadPositionStmt` in its transactions.
  Date: 2026-08-12
- Decision: Targeted reprojection touches neither the group's dedup rows nor any
  subscription checkpoint, and it does not insert dedup rows for the events it replays.
  Rationale: it is a repair of target rows, not a consumer rewind. An event committed
  before our lock whose async application is still pending will be applied by the async
  runner after our commit; if we replayed it too, the event is applied twice — but that is
  exactly the replay/redelivery overlap the full rebuild already has (replay applies through
  the captured head, then redelivery from the reset checkpoint re-processes), so the
  existing replay-safety contract (transaction-local, re-application-tolerant handlers,
  ADR-26) already covers it. Inserting dedup rows for replayed events was rejected: it
  would suppress the live async application and with it any live-only behavior, diverging
  from full-rebuild semantics.
  Date: 2026-08-12
- Decision: The operation refuses missing streams, soft-deleted streams, and streams whose
  visible per-stream history is shorter than their version counter (which detects logical
  truncation), each with a typed error.
  Rationale: the group's canonical reconstruction is the full `$all`/category replay, which
  still sees soft-deleted and pre-truncation events; a per-stream read does not. Repairing
  from a divergent history would make the targeted repair disagree with what a full rebuild
  would produce. Capturing `StreamInfo.version` after the lock and requiring exactly that
  many events to be read turns the divergence into a checked refusal instead of a caveat.
  Date: 2026-08-12
- Decision: The operator identity is `ProjectionId` plus `StreamName`
  (`rebuild reproject PROJECTION STREAM`), not a query-model name.
  Rationale: per ADR-26's identity separation the projection is the single owner of the
  targets being repaired, and one repair fixes every query model the owner supplies. The
  documentation shows how to find a model's supplying projection via the catalog inventory.
  Date: 2026-08-12
- Decision: A `declareStreamScopedRows` combinator upgrades a `Replayable` definition inside
  an already-built `ProjectionCatalog`, so keiro-dsl-generated catalogs can opt in without
  any `.keiro` language change. A language-5 surface is deliberately out of scope.
  Rationale: MasterPlan 41 assigns candidate-language amendments to EP-2 only, and the
  upgrade is type-preserving inside the existential `SomeProjectionSet` (it reuses the
  adapter already present in `Replayable`). If a language surface is wanted later it must be
  weighed against the language-5 candidate window closing at 0.12 (a later addition lands in
  language 6); this plan records that consequence rather than expanding into keiro-dsl.
  Date: 2026-08-12
- Decision: No new telemetry counters and no persisted run/audit state for reprojection.
  Rationale: adding a field to `KeiroMetrics` breaks application constructors, and a
  single-transaction repair has no resumable state to persist; the operator evidence is the
  `keiro-ops` JSON output (which echoes `requestedBy`/`requestReason`) plus the report. If
  operational audit pressure appears, a follow-up can add both deliberately.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This repository is a multi-package Haskell cabal project. The packages touched here are
`keiro` (the runtime library) and `keiro-ops` (the embeddable operator CLI). All paths below
are repository-relative from `/Users/shinzui/Keikaku/bokuno/keiro`.

### The projection catalog and its four identities

A *read model* is an application-owned PostgreSQL table kept up to date by *projections* —
handlers that apply events from the event store (the kiroku-store library,
`mori://shinzui/kiroku/packages/kiroku-store`) to that table. A service declares its whole
projection fleet in one typed *projection catalog*
(`keiro/src/Keiro/Projection/Catalog.hs`). Per
`docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`
the catalog keeps four identities separate: a *query model* is the typed read contract; a
*target* is one application-owned table; a *rebuild group* is the set of targets that move
through one lifecycle atomically; and a *projection* is the single ordered owner of one or
more targets. `validateProjectionCatalog` is a pure closed-world gate; only a
`ValidatedProjectionCatalog` reaches registration, replay, or operations code.

A projection's `ProjectionDefinition` (Catalog.hs, around line 412) carries a
`replayPolicy :: ProjectionReplayPolicy event` with today exactly two constructors
(around line 399):

```haskell
data ProjectionReplayPolicy event
  = Replayable !(ReplayAdapter event)
  | LiveOnly !LiveOnlyReason
```

A `ReplayAdapter event` (around line 375) is a pair of closures: `decodeForReplay` maps a
raw `RecordedEvent` to irrelevant / relevant-and-decoded / structured decode failure, and
`applyForReplay :: event -> RecordedEvent -> Tx.Transaction ()` applies one decoded event as
arbitrary application SQL inside a `hasql-transaction` transaction. Closures are never part
of catalog fingerprints; declared identities and versions are.

### How the full rebuild works and what it costs

`beginGroupRebuild` (`keiro/src/Keiro/ReadModel/Rebuild/Group.hs`, around line 458) locks
the group's registration row in `keiro.keiro_projection_rebuild_groups` with `FOR UPDATE`,
flips the group status to `rebuilding` and its bound query models to `rebuilding`, issues
one multi-table `TRUNCATE` over every `ClearBeforeReplay` target, deletes the group's
replayable async *dedup rows* (rows in `keiro.keiro_projection_dedup` recording which events
an async projection has already applied), and rewinds the group's *subscription checkpoints*
(durable per-subscription cursors owned by kiroku-store) to the replay start. The replay
runner (`keiro/src/Keiro/ReadModel/Rebuild/Runner.hs`) then pages history from the store —
`Kiroku.Store.Read.readAllForward` / `readCategory` between transactions — and applies each
chunk in one transaction through `runCatalogReplayAdapter`. Promotion is proof-driven and
returns the group to `live`.

The costs relevant here: during the whole window the group is *fenced* — every in-process
query gets a typed unavailability outcome, every writer of the group's targets is rolled
back, and (the point of IR-22) an out-of-process SQL reader silently sees a truncated then
progressively refilling table. `beginGroupRebuild` also resets group dedup and subscription
identities, because a full replay plus redelivery-from-zero is a consumer rewind. Targeted
reprojection must contrast with that on every axis: no status change, no truncate, no dedup
reset, no checkpoint rewind.

### How live writers fence, and why a row lock is enough

Both live write paths take a shared lock on the group registration row *inside the same
transaction* as their writes: inline command projections via `lockProjectionGroupsTx`
(Group.hs, around line 596; called from `applyCatalogProjectionsTx` in
`keiro/src/Keiro/Projection.hs`, around line 289) and async appliers via
`applyAsyncProjectionFromCatalog` (Projection.hs, around line 343). The statement is
`SELECT ... FOR SHARE` (`lockGroupForShareStmt`). PostgreSQL `FOR SHARE` locks conflict with
`FOR UPDATE` locks. Therefore a transaction that takes `FOR UPDATE` on the group row and
holds it until commit is *mutually exclusive with every committed target write in the
group* for its duration — without changing the group's status, and without ever blocking
plain `SELECT` readers, because PostgreSQL readers use MVCC snapshots and take no row locks.
Writers arriving during the repair simply wait on the lock and then proceed normally; they
do not receive fenced errors, because the status they observe after the wait is still
`live`.

`Kiroku.Store.Transaction.runTransaction` executes an opaque `Tx.Transaction` on the store's
pool; `Kiroku.Store.Effect.runTxOnPool` pins isolation to `ReadCommitted`. Under
`ReadCommitted` every statement takes a fresh snapshot, so any statement executed after the
`FOR UPDATE` grant observes everything committed before the grant. This combination — lock
first, then read — is what makes an in-transaction stream read sound. Reading the stream
before the transaction is *not* sound: an inline command could append event N+1 and update
stream X's row between our read and our lock, and the delete-then-replay of events 1..N
would silently erase N+1's effect.

### Per-stream reads exist and are usable in-transaction

kiroku-store's effect-level API (module `Kiroku.Store.Read` of
`mori://shinzui/kiroku/packages/kiroku-store`; locate the source checkout with
`mori registry show shinzui/kiroku --full`) exposes `readStreamForward :: StreamName -> StreamVersion -> Int32 -> Eff es (Vector
RecordedEvent)` with an exclusive cursor (`StreamVersion 0` reads from the beginning), and
`getStream :: StreamName -> Eff es (Maybe StreamInfo)` where `StreamInfo` carries `version`
(count of appended events) and `deletedAt` (soft-delete marker). Those run outside our
transaction, so they are not what we use. What we use: kiroku-store *publicly exports* its
prepared statements in `Kiroku.Store.SQL`, including

```haskell
readStreamForwardStmt :: Statement (Text, Int64, Int32) (Vector RecordedEvent)
getStreamStmt         :: Statement Text (Maybe StreamInfo)
```

Executing another library's exported statement inside our transaction is the sanctioned
composition pattern of
`docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md`
("every operator command is a thin adapter over an exported operation from the library that
owns the affected state") and has precedent in this repository:
`keiro/src/Keiro/ReadModel/Rebuild.hs` line 105 imports and executes
`Kiroku.Store.SQL.visibleGlobalHeadPositionStmt`, and `keiro/src/Keiro/DeadLetter/Replay.hs`
imports `readDeadLettersStmt`. keiro pins `kiroku-store >=0.6 && <0.7` and both statements
exist in 0.6.0.0, so no upstream change is needed.

One store-visibility asymmetry matters. The full rebuild reads `$all` or category pages,
which *include* events of soft-deleted streams and pre-truncation events ("Logical
truncation and soft deletion leave `$all` junctions intact" — Read.hs). Per-stream reads
return an empty vector for soft-deleted streams and hide pre-truncation events. A targeted
repair must therefore refuse streams where the two histories diverge; the Decision Log
entry above explains the checks (missing, soft-deleted, and `events read < StreamInfo
version`, the last of which detects truncation without needing a truncation column, since
`StreamInfo` does not expose one).

### The replay/redelivery overlap contract this operation inherits

For an async-handled projection, the *runtime* inserts the dedup row
(`applyAsyncProjectionUnfenced`, Projection.hs around line 365: dedup insert with
`ON CONFLICT DO NOTHING`, apply only when inserted) — the application's `applyForReplay`
closure does not consult dedup (see `jitsurei/src/Jitsurei/ReadModels.hs`,
`applyOrderAuditEvent`). After a full rebuild, replay has applied events through the
captured head *and* redelivery from the rewound checkpoint re-processes them; replay-safe
handlers must tolerate that re-application (ADR-26: replay handlers are transaction-local
and idempotent per event in their row effects). Targeted reprojection has exactly one
analogous window: an event committed before our lock whose async application is still
pending gets replayed by us and later applied once by the async runner. Same contract, no
new obligation. Events appended *after* our lock cannot have been target-applied before us
(their appliers block on `FOR SHARE`), so they apply cleanly on top after our commit.

### The operator surface being extended

`keiro/src/Keiro/Projection/Catalog/Operations.hs` is the operator-neutral library facade
(`ProjectionCatalogOperations`) that `keiro-ops` wraps. `keiro-ops/src/Keiro/Ops/Rebuild.hs`
hosts the `rebuild` command domain: `list`, `preview`, `start`, `status`, `resume`,
`abandon`, `adopt`. Every mutating command is two-phase per ADR-28: without `--force` it
runs only the read/preview path and prints the exact force re-invocation; with `--force` it
calls the supported mutation. Rebuild commands are mounted only in embedding binaries that
supply a validated catalog through `Keiro.Ops.Embed.AppHooks.projectionCatalog`; the
standalone binary cannot mount them. The new command follows all of this unchanged.

### Relationship to the sibling plans of MasterPlan 41

This plan has a soft dependency on EP-2
(`docs/plans/255-fence-out-of-process-read-model-reads-behind-a-sanctioned-sql-surface.md`):
targeted reprojection deliberately takes no group-wide fence, so if EP-2's sanctioned SQL
read surface has landed, an external reader calling it during a targeted reprojection keeps
getting successful answers throughout (the group stays `live`, which is exactly the liveness
the sanctioned surface checks), seeing pre-repair rows until the commit and repaired rows
after. The documentation milestone states that interaction using EP-2's vocabulary only if
EP-2 has landed by then; otherwise it states the same guarantee in terms of the group
registration row. Likewise the acceptance test asserts group liveness via EP-1's status
relation (`docs/plans/254-publish-a-documented-projection-status-relation-for-external-readers.md`)
if that relation exists when this plan is implemented, and via
`keiro.keiro_projection_rebuild_groups` / `keiro.keiro_read_models` registration state
otherwise. Neither sibling is required to implement or verify this plan.

### Relevant ADRs

- `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md` —
  the identities this plan attaches to; amended by M5 (new declared projection-level
  property, new lifecycle operation).
- `docs/adr/0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md` —
  the command must wrap a supported library API, be two-phase, and respect schema ownership;
  this plan adds the library API first and the command as a thin adapter.
- `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md` —
  fingerprint identity rules; amended by M5 with the deliberate exclusion of the new
  declaration from preimages.
- `docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` — no keiro schema
  change is made by this plan (no new tables, no migration), so it is context only.

No other ADR in `docs/adr/` bears on this work (scanned by filename and headings).


## Plan of Work

The work is five milestones. Each is independently verifiable; the first two carry the
design weight.

### Milestone 1 — declare the row-per-aggregate property in the catalog

Scope: the typed declaration, its derived views, and proof that catalog identity is
untouched. At the end of this milestone an application can declare, per projection, that
its targets are stream-scoped, validation accepts it, inventory reports show it, and both
fingerprints ignore it. No runtime operation exists yet.

In `keiro/src/Keiro/Projection/Catalog.hs`:

1. Add the declaration record next to `ReplayAdapter` (define the term where it is
   introduced — the Haddock must spell out the exact safety property the application
   asserts, verbatim from the "declared property" paragraph in the Validation section
   below):

   ```haskell
   -- | Application assertion that one projection's owned targets are
   -- row-per-aggregate, plus the closure that clears one stream's rows.
   data StreamScopedRows = StreamScopedRows
     { clearStreamRows :: !(StreamName -> Tx.Transaction Int64)
     }
     deriving stock (Generic)
   ```

   `clearStreamRows` returns the number of rows it deleted (from `rowsAffected`) so the
   operation can report it. Import `StreamName` from `Kiroku.Store.Types`.

2. Extend the replay policy with a third constructor:

   ```haskell
   data ProjectionReplayPolicy event
     = Replayable !(ReplayAdapter event)
     | ReplayableStreamScoped !(ReplayAdapter event) !StreamScopedRows
     | LiveOnly !LiveOnlyReason
   ```

   Then chase every pattern match the compiler reports. The known sites, all inside this
   file: `collectProjectionFacts` (sets `factReplayable`; both replayable constructors are
   replayable), `catalogReplayAdapters` (around line 1096; the list comprehension currently
   binds `Replayable adapter <- [definition ^. #replayPolicy]` — replace with a helper
   `replayAdapterOf :: ProjectionReplayPolicy event -> Maybe (ReplayAdapter event)` so both
   constructors contribute their adapter), and the replay diagnostics in
   `replayDiagnostics`. Build `cabal build all` and let GHC's exhaustiveness warnings find
   any site this list missed. Behavior rule everywhere: `ReplayableStreamScoped` behaves
   exactly like `Replayable` plus one extra capability; the full-rebuild path must be
   byte-for-byte indifferent to the distinction.

3. Record the capability in facts and inventory: add `factStreamScoped :: Bool` to
   `ProjectionFacts`, populate it in `collectProjectionFacts`, add
   `streamScopedRows :: Bool` to `InventoryProjection`, populate it in
   `inventoryProjection`. Do **not** touch `projectionPreimage` or any other preimage
   function — the fingerprint exclusion is deliberate (Decision Log). Extend
   `renderInventory`'s `renderProjection` (around line 2171) with one extra field
   (`"stream-scoped"` / `"whole-table"`) so operator text output shows it.

4. Add the existential accessor the runner will use, reusing the existing
   `CatalogReplayAdapter` existential rather than inventing a second one:

   ```haskell
   data CatalogStreamReprojection = CatalogStreamReprojection
     { reprojectionProjectionId :: !ProjectionId,
       reprojectionGroupId :: !RebuildGroupId,
       reprojectionSourceScope :: !SourceScope,
       reprojectionAdapter :: !CatalogReplayAdapter,
       reprojectionScopedRows :: !StreamScopedRows
     }

   catalogStreamReprojection ::
     ValidatedProjectionCatalog ->
     ProjectionId ->
     Maybe CatalogStreamReprojection
   ```

   It scans `originalCatalog ^. #projectionSets` for the definition with the wanted id and
   a `ReplayableStreamScoped` policy, wraps the adapter as a `CatalogReplayAdapter` (order
   0 — order is meaningless for a single-projection replay), and resolves the source scope
   from the inventory source of the owning projection set.

5. Add the opt-in combinator for generated catalogs:

   ```haskell
   data StreamScopedDeclarationError
     = StreamScopedProjectionUnknown !ProjectionId
     | StreamScopedProjectionNotReplayable !ProjectionId

   declareStreamScopedRows ::
     ProjectionId ->
     StreamScopedRows ->
     ProjectionCatalog ->
     Either StreamScopedDeclarationError ProjectionCatalog
   ```

   It maps over `projectionSets`, and inside each `SomeProjectionSet` upgrades the matching
   definition's `Replayable adapter` to `ReplayableStreamScoped adapter scoped` (this is
   type-preserving inside the existential because the adapter is reused, not rebuilt).
   `LiveOnly` yields `StreamScopedProjectionNotReplayable`; no match anywhere yields
   `StreamScopedProjectionUnknown`. An already-stream-scoped definition is replaced
   idempotently. Applications built from keiro-dsl call this on the generated
   `projectionCatalog` value before validating; hand-written catalogs may use either the
   constructor or the combinator.

6. Export the new names from the module export list: `StreamScopedRows (..)`,
   `StreamScopedDeclarationError (..)`, `declareStreamScopedRows`,
   `CatalogStreamReprojection (..)`, `catalogStreamReprojection`.
   (`ProjectionReplayPolicy (..)` already exports all constructors.)

7. Extend the operations JSON in `keiro/src/Keiro/Projection/Catalog/Operations.hs`:
   `projectionValue` gains `"streamScopedRows" Aeson..= (projection ^. #streamScopedRows)`.

Tests for this milestone are pure and go in `keiro/test/CatalogSpec.hs` (validation and
combinator behavior) and `keiro/test/PreimageSpec.hs` or `keiro/test/CatalogEvolutionSpec.hs`
(fingerprint neutrality): build the existing `CatalogSpec.validCatalog`, produce a second
catalog by `declareStreamScopedRows` on its counter projection with a dummy closure, and
assert `catalogFingerprint` and `groupSliceFingerprint` are equal across the pair while
`streamScopedRows` differs in inventory. Also assert both combinator error cases.

Acceptance: `cabal build all` clean (no new warnings) and `cabal test keiro-test` passes
including the new pure specs. `cabal test keiro-dsl:tests` still passes untouched — if any
keiro-dsl golden fails, something changed observable identity and must be fixed, not
regenerated, because this milestone is defined as identity-neutral.

### Milestone 2 — the reprojection runner and its database tests

Scope: the supported library operation with the full transactional shape, plus DB tests
proving every promised property. At the end, `reprojectStream` exists, is re-exported from
`Keiro.ReadModel.Rebuild`, and a test suite demonstrates one-row repair with the group live
throughout.

Create `keiro/src/Keiro/ReadModel/Rebuild/Reproject.hs` (add to `other-modules` in
`keiro/keiro.cabal` next to `Keiro.ReadModel.Rebuild.Runner`, around line 98). Shape:

```haskell
{-# OPTIONS_HADDOCK hide #-}

-- | Targeted per-stream reprojection: repair one aggregate's rows in a
-- stream-scoped projection without taking the group fence.
module Keiro.ReadModel.Rebuild.Reproject
  ( ReprojectStreamRequest (..),
    StreamReprojectionError (..),
    StreamReprojectionReport (..),
    reprojectStream,
  )
where
```

Types (all with `deriving stock (Eq, Show, Generic)` where the payloads allow):

```haskell
data ReprojectStreamRequest = ReprojectStreamRequest
  { reprojectionProjection :: !ProjectionId,
    reprojectionStream :: !StreamName,
    requestedBy :: !Text,
    requestReason :: !Text,
    readPageSize :: !Int32
  }

data StreamReprojectionError
  = ReprojectionInvalidPageSize !Int32
  | ReprojectionProjectionNotInCatalog !ProjectionId
  | ReprojectionNotDeclared !ProjectionId
  | ReprojectionStreamOutsideSource !ProjectionId !Text !StreamName
  | ReprojectionGroupUnregistered !RebuildGroupId
  | ReprojectionGroupSliceDrift !RebuildGroupId !Text !Text
  | ReprojectionGroupNotLive !RebuildGroupId !GroupLifecycleStatus !(Maybe RebuildRunId)
  | ReprojectionStreamNotFound !StreamName
  | ReprojectionStreamSoftDeleted !StreamName
  | ReprojectionStreamHistoryIncomplete !StreamName !Int64 !Int64
  | ReprojectionDecodeFailed !ProjectionId !StreamName !GlobalPosition !ReplayDecodeError

data StreamReprojectionReport = StreamReprojectionReport
  { reportProjection :: !ProjectionId,
    reportGroup :: !RebuildGroupId,
    reportStream :: !StreamName,
    streamVersionAtRepair :: !Int64,
    rowsCleared :: !Int64,
    eventsRead :: !Int64,
    eventsApplied :: !Int64,
    eventsIrrelevant :: !Int64,
    requestedBy :: !Text,
    requestReason :: !Text
  }
```

`reprojectStream :: (Store :> es) => ValidatedProjectionCatalog -> ReprojectStreamRequest
-> Eff es (Either StreamReprojectionError StreamReprojectionReport)` proceeds:

Pure pre-checks, outside any transaction: refuse `readPageSize <= 0`
(`ReprojectionInvalidPageSize`); look up the projection in
`catalogInventory ... inventoryProjections` — absent means
`ReprojectionProjectionNotInCatalog`, present without a `catalogStreamReprojection` result
means `ReprojectionNotDeclared`; when the reprojection's `reprojectionSourceScope` is
`CategorySource c`, compute the stream's category as the `StreamName` text before the first
`-` (the documented kiroku convention, see `readCategory`'s Haddock) and refuse a mismatch
with `ReprojectionStreamOutsideSource` carrying the expected category text. `AllStreams`
sources accept any stream.

Then one `runTransaction` whose body is, in this exact order (the order is load-bearing —
the lock must be the first statement so every later statement's `ReadCommitted` snapshot
postdates the lock grant):

1. `Tx.statement (rebuildGroupIdText groupId) lockGroupForUpdateStmt` — export
   `lockGroupForUpdateStmt` from `Keiro.ReadModel.Rebuild.Group` (it is module-internal
   today, around line 729; both modules are `other-modules` of the same library, so this
   widens no public API). `Nothing` → condemn, `ReprojectionGroupUnregistered`. Then
   compare `sliceFingerprint` with the compiled catalog's
   `groupSliceFingerprint catalog groupId` (drift → condemn,
   `ReprojectionGroupSliceDrift stored current`) and require `status == GroupLive`
   (otherwise condemn, `ReprojectionGroupNotLive` with the active run id). A rebuilding or
   failed group refuses: a full rebuild will rewrite everything anyway, and a failed group
   needs group-level recovery, not a row repair.
2. `Tx.statement streamText Kiroku.Store.SQL.getStreamStmt` — `Nothing` → condemn,
   `ReprojectionStreamNotFound`; `Just info` with `deletedAt` set → condemn,
   `ReprojectionStreamSoftDeleted`. Capture `capturedVersion = info ^. #version` (an
   `Int64`-compatible `StreamVersion`; unwrap as the store types dictate).
3. `clearStreamRows scopedRows streamName` — the application closure; keep its returned
   count.
4. Page the stream inside the transaction: loop
   `Tx.statement (streamText, cursor, readPageSize) Kiroku.Store.SQL.readStreamForwardStmt`
   starting at cursor 0 (exclusive), advancing the cursor to the last event's
   `streamVersion`, and *stop consuming at `capturedVersion`* — drop any event whose
   `streamVersion` exceeds it (a concurrent append during our transaction; its own
   application paths handle it after our commit, exactly like the full rebuild's captured
   head discipline). For each kept event call
   `runCatalogReplayAdapter (reprojectionAdapter reprojection) recorded`
   (`keiro/src/Keiro/Projection/Catalog.hs`, around line 802): `Right False` counts
   irrelevant, `Right True` counts applied, `Left decodeError` → condemn,
   `ReprojectionDecodeFailed` with the event's `globalPosition`. Stop paging when a page
   returns fewer rows than `readPageSize` or the cursor reached `capturedVersion`.
5. After the loop require `eventsRead == capturedVersion`; otherwise condemn with
   `ReprojectionStreamHistoryIncomplete stream capturedVersion eventsRead`. This is the
   truncation/visibility guard from the Decision Log: `StreamInfo.version` counts appended
   events while the per-stream read returns only visible ones, so any hidden prefix makes
   the counts diverge and the repair refuses rather than reconstruct from partial history.
6. Return the report.

On any `Left`, the transaction is condemned, so the delete from step 3 rolls back and the
table is untouched — a failed reprojection leaves no trace. Note in the module Haddock the
one operational caution: the group row is write-locked for the duration, so concurrent
writers of the same group stall (they wait, they do not error) while one stream's history
replays; this operation is sized for row-per-aggregate repair (one aggregate's stream), and
a pathologically long stream is a reason to schedule the repair, not a correctness problem.

Re-export `ReprojectStreamRequest (..)`, `StreamReprojectionError (..)`,
`StreamReprojectionReport (..)`, and `reprojectStream` from the public facade
`keiro/src/Keiro/ReadModel/Rebuild.hs` (add to its import and export lists, in the catalog
section of the export list).

Tests: create `keiro/test/StreamReprojectSpec.hs`, register it in `keiro/keiro.cabal`'s
`test-suite keiro-test` `other-modules` and call it from `keiro/test/Main.hs` alongside
`GroupRebuildSpec.spec fixture` (around line 399). Follow the established pattern exactly:
`spec :: Fixture -> Spec`, `around (withFreshStore fixture)` from `Keiro.Test.Postgres`
(`keiro-test-support`), which hands each example a fresh database cloned from the
suite-level template — never per-example migrations. Build a dedicated catalog fixture in
the spec: one category source (`CategorySource "orders"`), one target
`app.order_rows (stream_name text primary key, total bigint, last_position bigint)`
created by a `Tx.sql` fixture statement, one inline projection whose
`applyForReplay` upserts the row keyed by the event's source stream name, declared
`ReplayableStreamScoped` with `clearStreamRows` = `DELETE FROM app.order_rows WHERE
stream_name = $1` returning the affected count, one rebuild group, one query model. A
second variant registers an async-handled projection (mirror `CatalogSpec`'s async fixture)
to test dedup non-interaction. Events are appended with the `appendRaw` helper pattern from
`keiro/test/ProjectionReplaySpec.hs` (around line 458) to streams `orders-1`, `orders-2`,
`orders-3`.

The specific examples this suite must contain are listed under Validation and Acceptance.

Acceptance: `cabal test keiro-test` passes with the new spec; the spec fails if the
implementation takes any status transition (asserted by comparing the full group row before
and after), touches other rows (asserted by `row_to_json` plus system column `xmin`
equality), or resets dedup/checkpoints.

### Milestone 3 — operator-neutral wrappers in `ProjectionCatalogOperations`

Scope: the preview/execute pair `keiro-ops` will wrap, with versioned JSON envelopes,
following the existing report conventions in
`keiro/src/Keiro/Projection/Catalog/Operations.hs`.

Add:

```haskell
data StreamReprojectionPreview = StreamReprojectionPreview
  { reportSchema :: !Text,                       -- "keiro/catalog-reprojection-preview/v1"
    projectionId :: !ProjectionId,
    rebuildGroupId :: !RebuildGroupId,
    stream :: !StreamName,
    declaredStreamScoped :: !Bool,
    targets :: ![InventoryTarget],
    sourceScope :: !(Maybe SourceScope),
    registeredState :: !(Maybe GroupRebuildMetadata),
    registeredSliceMatches :: !(Maybe Bool)
  }

data StreamReprojectionOutcome = StreamReprojectionOutcome
  { reportSchema :: !Text,                       -- "keiro/catalog-reprojection-outcome/v1"
    outcome :: !StreamReprojectionReport
  }

previewStreamReprojection ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  ProjectionId ->
  StreamName ->
  Eff es (Either CatalogOpsError StreamReprojectionPreview)

runStreamReprojection ::
  (Store :> es) =>
  ProjectionCatalogOperations ->
  ReprojectStreamRequest ->
  Eff es (Either CatalogOpsError StreamReprojectionOutcome)
```

The preview is total for any projection present in the inventory (unknown projection →
new `CatalogOpsUnknownProjection !ProjectionId`); it renders `declaredStreamScoped = False`
rather than failing, so an operator previewing an undeclared projection sees exactly why the
mutation would refuse. It reads the group registration row via
`lookupProjectionRebuildGroup` (read-only) like `previewRegisteredGroupRebuild` does.
`runStreamReprojection` delegates to `reprojectStream` and wraps errors in a new
`CatalogOpsReprojectionRefused !StreamReprojectionError` constructor on `CatalogOpsError`.
Add `Aeson.ToJSON` instances for both envelopes in the file's existing hand-rolled style
(schema first; stream as its text; reuse `targetValue`, `groupMetadataValue`,
`sourceScopeValue`).

Tests extend `keiro/test/CatalogOperationsSpec.hs`: preview of a declared and an undeclared
projection, unknown projection error, and one end-to-end `runStreamReprojection` happy path
reusing the M2 fixture catalog.

Acceptance: `cabal test keiro-test` passes.

### Milestone 4 — the `keiro-ops rebuild reproject` command

Scope: the thin CLI adapter with the standard two-phase force policy and a transcript test.

In `keiro-ops/src/Keiro/Ops/Rebuild.hs`: extend `Command` with
`Reproject !ReprojectOptions` where

```haskell
data ReprojectOptions = ReprojectOptions
  { projectionId :: !ProjectionId,
    stream :: !StreamName,
    requestedBy :: !Text,
    reason :: !Text,
    pageSize :: !Int32
  }
```

Parser: subcommand `reproject` with positional `PROJECTION` (a new `projectionReader` via
`mkProjectionId`, mirroring `groupReader`) and `STREAM` (plain text wrapped in
`StreamName`), options `--requested-by`, `--reason`, `--page-size` (default 500, positive).
`isMutation (Reproject {}) = True`. `runCommand`: with `env.force`, call
`runStreamReprojection` and render an `OpsResult` with headers
`["projection", "group", "stream", "stream_version", "rows_cleared", "events_read",
"events_applied", "events_irrelevant"]`; without force, call `previewStreamReprojection`
and return `PreviewRequired` with `forceInvocation env (reprojectArguments options)`
(mirror `startArguments`). JSON output is `Aeson.toJSON` of the envelope, as everywhere in
this file. The command is automatically embedded-only because the whole rebuild domain
mounts through `AppHooks.projectionCatalog` (`keiro-ops/src/Keiro/Ops/Embed.hs`); no
mounting change is needed, but add the two parser assertions (standalone parse fails,
embedded parse succeeds) next to the existing ones in `keiro-ops/test/Main.hs` around
line 115.

Test in `keiro-ops/test/Main.hs`, in the catalog describe block around line 142, following
the adoption test's structure: build a small stream-scoped catalog + `app` table, seed
events, register, corrupt one row by direct SQL, run the command without force (assert
`isPreview`, assert the printed force invocation equals
`'keiro-ops' 'rebuild' 'reproject' '<projection>' 'orders-1' '--requested-by' ... '--force'`),
run with force, assert the outcome row counts and that the corrupted row is repaired while
the other row is unchanged.

Acceptance: `cabal test keiro-ops-test` passes.

### Milestone 5 — documentation, ADR amendments, changelogs

Scope: make the capability discoverable and its contract durable.

Documentation: add a section `## Reproject One Stream` to
`docs/user/read-models-and-projections.md` after `## Replay A Catalog Group`. It must:
define row-per-aggregate; show the declaration (constructor form and
`declareStreamScopedRows` form for generated catalogs, noting there is deliberately no
`.keiro` language surface yet); spell out the declared safety property verbatim (see
Validation); state the operational semantics — no fence, group stays live, writers of the
group briefly wait on a row lock, dedup and checkpoints untouched, the replay/redelivery
overlap contract, the refusal list (undeclared, unknown, category mismatch, missing,
soft-deleted, incomplete history, non-live group, slice drift, decode failure → rollback);
show the `keiro-ops` transcript; and state the out-of-process reader interaction. For that
last paragraph: if `docs/plans/255-...`'s sanctioned SQL surface exists in the tree by the
time you write this, name it and say its reads keep succeeding throughout a targeted
reprojection because the group never leaves live service; otherwise phrase the same
guarantee against the registration row and leave a one-line pointer to IR-22 capability 1.
Also add a row to the operate section (`## Inspect And Operate A Catalog`) mentioning the
command.

ADR amendments (follow `agents/skills/exec-plan/ADR.md`; the bundle is profile-governed —
`docs/adr/profile.dhall` exists — so update `timestamp` fields, append to `docs/adr/log.md`
with `okf log add`, and run the strict validation below):

- Amend
  `docs/adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md`:
  in the Decision section, after the reset-policy/replay-policy paragraph, add a paragraph
  defining the stream-scoped-rows declaration (projection-level, unchecked-SQL assertion
  like every catalog declaration, with the structural head-capped completeness check) and
  the targeted reprojection operation (single-transaction delete-then-replay under the
  group registration row's exclusive lock; no lifecycle transition; dedup and subscription
  identities untouched). In Consequences, add that a projection bug in a row-per-aggregate
  model no longer forces a group fence, and that stream-scoped repair refuses soft-deleted
  and truncated streams because per-stream visible history diverges from `$all` replay.
- Amend
  `docs/adr/0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md`:
  one paragraph in the Decision section, parallel to the derived-supplier paragraph,
  stating that the stream-scoped declaration and its inventory flag are deliberately
  excluded from catalog and slice preimages and why (capability metadata; changes no
  preparation/writer/replay fact; enabling repair must not force adoption).
- Create a new ADR instead only if, while writing, the ADR-26 amendment visibly overloads
  that record; in that case allocate the next handle with `okf id next` and cross-link from
  ADR-26. The default is to amend.

Changelogs: `keiro/CHANGELOG.md` `Unreleased` → `### Added` entry for the declaration,
combinator, `reprojectStream`, and operations wrappers; `keiro-ops/CHANGELOG.md`
`Unreleased` → `### Added` entry for `rebuild reproject`.

Acceptance: strict OKF validation passes, `just verify` passes end-to-end.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.

Build and targeted tests, after each milestone:

```bash
cabal build all
cabal test keiro-test
cabal test keiro-ops-test
cabal test keiro-dsl:tests
cabal test keiro-migrations-test
```

The `keiro-test` and `keiro-ops-test` suites start one ephemeral PostgreSQL server and one
migrated template database per run (via `keiro-test-support`); each example clones the
template. No local database setup is required. Expected shape of a passing targeted run:

```text
Finished in ... seconds
... examples, 0 failures
Test suite keiro-test: PASS
```

ADR validation after M5 (exact commands from `agents/skills/exec-plan/ADR.md`):

```bash
okf log add docs/adr --profile docs/adr/profile.dhall
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Full gate at the end:

```bash
just verify
```

Commit and trailer convention: commit frequently, one coherent change per commit, using
Conventional Commits (`feat(catalog): ...`, `feat(rebuild): ...`, `feat(keiro-ops): ...`,
`test(rebuild): ...`, `docs(user): ...`, `docs(adr): ...`) and include on every commit the
trailers:

```text
MasterPlan: docs/masterplans/41-make-read-models-safely-readable-by-out-of-process-consumers.md
ExecPlan: docs/plans/257-add-targeted-per-stream-reprojection-to-catalog-operations.md
Intention: intention_01kzw6dkhje7qvw6w321pwyv12
```


## Validation and Acceptance

The declared property (this exact wording goes in the Haddock of `StreamScopedRows` and in
the user guide; it is what an application asserts and what the tests verify on the test
fixture): *for every stream X in the projection's source scope, every row this projection's
handlers write when applying an event of X is keyed by X and is never written when applying
any other stream's events; `clearStreamRows X` deletes exactly those rows; and replaying
X's visible events from version zero through the replay adapter after `clearStreamRows X`
reconstructs them.* Like every catalog declaration, the SQL side is asserted, not proven
(ADR-26's unchecked SQL boundary); the runtime verifies what it can structurally — that it
read the complete visible history (`eventsRead == capturedVersion`) and refuses streams
whose visible history diverges from full-replay history.

`keiro/test/StreamReprojectSpec.hs` must contain at least these examples, each phrased as
observable behavior:

1. Repairs exactly one aggregate. Seed `orders-1`, `orders-2`, `orders-3` with events;
   register; run one full rebuild or apply events live so rows exist; corrupt `orders-1`'s
   row with direct SQL (`UPDATE app.order_rows SET total = 999999 WHERE stream_name =
   'orders-1'`); capture `SELECT stream_name, row_to_json(t), xmin FROM app.order_rows t
   WHERE stream_name <> 'orders-1' ORDER BY stream_name`; run `reprojectStream`; assert the
   report (`rowsCleared = 1`, `eventsRead = eventsApplied + eventsIrrelevant`,
   `eventsRead == streamVersionAtRepair`); assert `orders-1`'s row equals the value
   recomputed from its events; re-capture the other rows and assert both `row_to_json` and
   `xmin` are identical — byte-stable and never rewritten.
2. Takes no group-wide fence. Capture the full `keiro.keiro_projection_rebuild_groups` row
   and the `keiro.keiro_read_models` rows for the group before the reprojection; assert
   after that every column is unchanged — status still `live`, `active_run_id` null,
   `started_at`/`completed_at`/`last_built_at` untouched. If EP-1's documented status
   relation exists in the schema by implementation time, additionally `SELECT` it and
   assert the group reads as live with an unchanged position; otherwise the registration
   rows above are the assertion (this is the soft-dependency branch from Context). Then
   prove writers still work: apply a live inline command for `orders-2` and an async event
   through `applyAsyncProjectionFromCatalog` after the repair and assert both succeed.
3. Leaves consumer identities alone. With the async-handled fixture variant: apply several
   events through `applyAsyncProjectionUnfenced` so dedup rows exist; capture
   `SELECT projection_name, event_id FROM keiro.keiro_projection_dedup ORDER BY 1, 2` and
   the subscription checkpoint inventory; reproject; assert both sets are identical
   afterwards, and assert the target row was still reconstructed (proving replay does not
   consult dedup).
4. Refuses everything it must, each with the exact typed error: a `Replayable`-only
   projection (`ReprojectionNotDeclared`), an unknown projection id
   (`ReprojectionProjectionNotInCatalog`), a stream from another category
   (`ReprojectionStreamOutsideSource`), a never-created stream
   (`ReprojectionStreamNotFound`), a soft-deleted stream — soft-delete via
   `Kiroku.Store.Lifecycle.softDeleteStream` — (`ReprojectionStreamSoftDeleted`), a
   truncated stream — `Kiroku.Store.Lifecycle.setStreamTruncateBefore` then reproject —
   (`ReprojectionStreamHistoryIncomplete` with the expected/read counts), a group mid-
   rebuild — `beginGroupRebuild` first — (`ReprojectionGroupNotLive`), and slice drift —
   register with one codec fingerprint, reproject with a differently-fingerprinted catalog,
   mirroring `GroupRebuildSpec`'s drift example — (`ReprojectionGroupSliceDrift`).
5. Rolls back completely on failure. Use an adapter whose decoder fails on one seeded
   poison event: assert `ReprojectionDecodeFailed` and that the target rows (including
   stream X's) are byte-identical to before the attempt — the delete rolled back.

The `keiro-ops` acceptance is a transcript: running without `--force` prints the preview
and the exact force invocation and exits unsuccessfully with no mutation (assert the
corrupted row is still corrupted); running with `--force` prints the outcome row and the
row is repaired. Capture the transcript shape in the test assertions as the adoption test
does (`shouldBe` on the force invocation string).

The IR-22 acceptance sentence this plan discharges, restated as the final check: reproject
one aggregate into a row-per-aggregate model and observe that only that aggregate's row
changes and no group-wide fence is taken — which is exactly examples 1 and 2 plus the
transcript.


## Idempotence and Recovery

The operation is one transaction with no persisted run state. Any failure — typed refusal,
decode failure, closure exception, crash, connection loss — rolls the transaction back,
leaving the table, the registration rows, dedup, and checkpoints exactly as they were;
there is nothing to clean up and no abandoned state to recover. Re-running a successful
reprojection is also safe: it deletes and reconstructs the same rows from the same history
(plus any events appended in between), so the operation is idempotent at the row level.
Every test example can therefore be re-run freely, and an operator interrupted mid-repair
simply re-issues the command.

Implementation steps are additive until M5's documentation edits; each milestone leaves
`cabal build all` and the targeted suites green, so work can stop and resume at any
milestone boundary. If an implementation attempt corrupts a test database, delete nothing:
the suites create a fresh ephemeral server per run.


## Interfaces and Dependencies

Libraries: `keiro` (runtime), `keiro-ops` (CLI), `keiro-test-support` (ephemeral-pg
template fixture), and kiroku-store 0.6 (`mori://shinzui/kiroku/packages/kiroku-store`)
from Hackage — specifically its exported `Kiroku.Store.SQL.readStreamForwardStmt` and
`getStreamStmt` statements, `Kiroku.Store.Types.StreamName`/`StreamVersion`/`StreamInfo`,
and `Kiroku.Store.Lifecycle` soft-delete/truncation helpers (tests only). No version bump
and no upstream change are required; the existing bound `>=0.6 && <0.7` in
`keiro/keiro.cabal` already covers everything used.

Signatures that must exist at the end of each milestone:

- M1, `Keiro.Projection.Catalog`:
  `StreamScopedRows (..)` with `clearStreamRows :: StreamName -> Tx.Transaction Int64`;
  `ReplayableStreamScoped :: ReplayAdapter event -> StreamScopedRows ->
  ProjectionReplayPolicy event`;
  `declareStreamScopedRows :: ProjectionId -> StreamScopedRows -> ProjectionCatalog ->
  Either StreamScopedDeclarationError ProjectionCatalog`;
  `catalogStreamReprojection :: ValidatedProjectionCatalog -> ProjectionId ->
  Maybe CatalogStreamReprojection`;
  `InventoryProjection` with `streamScopedRows :: Bool`.
- M2, `Keiro.ReadModel.Rebuild` (facade re-export of
  `Keiro.ReadModel.Rebuild.Reproject`):
  `reprojectStream :: (Store :> es) => ValidatedProjectionCatalog ->
  ReprojectStreamRequest -> Eff es (Either StreamReprojectionError
  StreamReprojectionReport)`; `Keiro.ReadModel.Rebuild.Group` additionally exports
  `lockGroupForUpdateStmt` for intra-library reuse.
- M3, `Keiro.Projection.Catalog.Operations`:
  `previewStreamReprojection` and `runStreamReprojection` as specified in M3, plus
  `CatalogOpsError` extended with `CatalogOpsUnknownProjection` and
  `CatalogOpsReprojectionRefused`.
- M4, `Keiro.Ops.Rebuild`: `Command` extended with `Reproject !ReprojectOptions`;
  `isMutation` returns `True` for it; `runCommand` handles both phases.

Interfaces this plan must not change: the full-rebuild lifecycle (`beginGroupRebuild`,
runner, promotion proofs) behaves identically for `ReplayableStreamScoped` and `Replayable`
projections; catalog and slice fingerprint values for any catalog expressible today are
unchanged (tested); the hot write paths (`applyCatalogProjectionsTx`,
`applyAsyncProjectionFromCatalog`) are not edited at all — the new operation composes with
their existing `FOR SHARE` discipline purely through the database lock.
