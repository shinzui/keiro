# Read Models And Projections

Read models are query-optimized views derived from the event log. Keiro provides
metadata, query-freshness helpers, inline projection support, and at-least-once async
projection helpers.

## Declare One Projection Catalog

`Keiro.Projection.Catalog` lets an application declare the whole read-side
inventory once and validate it before any registration or rebuild effect. The
catalog deliberately separates four identities:

- a query-model binding retains a typed `ReadModel q r` and says which targets
  the query observes;
- a physical target names one application-owned qualified PostgreSQL table and
  its reset policy;
- a rebuild group lists the targets that must move through one lifecycle in a
  deterministic dependency order; and
- a projection definition is the single owner of one or more targets and holds
  an explicitly ordered list of inline or async handlers.

Target reset policy is not replay safety. `ClearBeforeReplay` and
`PreserveAndReconcile` say what happens to a table before replay.
`Replayable adapter` and `LiveOnly reason` say whether a handler has a safe
replay path. This distinction allows a live handler to omit external effects
from its explicit replay adapter and allows brownfield tables to be reconciled
without claiming complete historical reconstruction.

Every async subscription also declares `checkpointOnMissing`, the policy Kiroku
uses only when the exact durable member row does not exist:

```haskell
SubscriptionDeclaration
  { subscriptionId = ordersSubscriptionId
  , subscriptionName = "orders-summary"
  , subscriptionSource = ordersSourceId
  , checkpointOnMissing = FromBeginning
  , claimSite = ordersSubscriptionClaim
  }
```

Choose `FromBeginning` for a consumer that must process existing history,
`FromCurrentHead` for a future-only consumer, or `FailIfMissing` when missing
worker state is an operational error. An existing member row always wins and is
never moved by this policy. The value is part of registration, inventory,
fingerprints, human output, and JSON. A replayable owner of a
`ClearBeforeReplay` target cannot use `FromCurrentHead`, because clearing the
target and then skipping history could never reconstruct it. Preserve/reconcile
and live-only ownership retain all three choices.

Build `SourceDeclaration`, `TargetDeclaration`,
`RebuildGroupDeclaration`, subscription/dedup declarations, query-model
bindings, and typed `ProjectionSet event` values, then combine them in a
`ProjectionCatalog`:

```haskell
case validateProjectionCatalog catalog of
  Failure diagnostics ->
    traverse_ (print . diagnosticCodeText . (^. #diagnosticCode)) diagnostics
  Success validated -> do
    let liveOrderHandlers = typedInlineProjections validated orderProjectionSet
        querySuppliers = resolvedQuerySupplies validated
        inventory = catalogInventory validated
        fingerprint = catalogFingerprint validated
    registerApplicationReadSide inventory
    runOrderWriter liveOrderHandlers
```

The `ValidatedProjectionCatalog` constructor is hidden. Use
`useProjectionCatalogM` when registration is effectful; it does not invoke the
callback after failed validation. Inventory rendering and SHA-256 fingerprints normalize
top-level declarations, query observed targets, and each projection's set-valued owned
targets. Current `catalog-v4`/`slice-v3` identity includes normalized query freshness,
the optional subscription cursor resolved from the validated owner, and projection
revision schema/provisioner/validator/handler/promotion identities. Handler and
provisioning closures are excluded from the fingerprint.

Every validated query binding also resolves to exactly one supplying projection
through target ownership. `resolvedQuerySupplies` returns query model, projection,
group, sorted non-empty observed targets, source, and the owner's complete ordered
handler-capability list. It never selects a handler by list position and contains no
closures. A query that observes targets owned by different projections is invalid;
several queries may observe different subsets of one owner's targets and all resolve to
that same owner. The query's backing target remains a separate physical SQL choice and
does not determine its supplier.

Inventory records each query's normalized freshness and optional resolved cursor. An
immediate query remains valid without a cursor. A head or position wait must have exactly
one compatible durable cursor among its owner's handlers; zero or several candidates
produce stable, fully attributed catalog diagnostics instead of first-match selection.

Validation reports deterministic codes and every conflicting `ClaimSite`. It
rejects duplicate logical or physical identities, unknown references, targets
without exactly one projection owner, cross-group writes, dependency cycles,
unsafe clear/replay combinations, and overlapping `$all` plus category sources
inside one group. Several distinct category sources are allowed because their
recorded events can later be merged by global position.

This is a closed-world structural proof. Keiro cannot inspect arbitrary Hasql
transactions or discover undeclared tables. Your application continues to own
DDL, migrations, SQL, row codecs, and the truthfulness of target declarations.
Use `compareCatalogBaseline old new` separately when a persisted prior inventory
must reveal a declaration that was removed completely.

Existing callers remain source-compatible. The `unmanagedInlineProjections`,
`unmanagedAsyncProjection`, and `unmanagedReadModel` wrappers label values that
remain outside catalog validation while an application migrates incrementally.

### Generate the catalog from candidate Language 5

`keiro-dsl` language 5 is the current unreleased candidate. Its checked graph
owns the same runtime catalog described above. Language 1–4 meanings and
generated banners remain unchanged; an existing service adopts 5 explicitly
when it is ready to describe every physical target, rebuild group, projection
owner, source, and query binding.

A language-4 singleton read model puts physical authority on the query node:

```text
language keiro-dsl 4

readmodel orderSummary {
  schema = "sales"
  table = "order_summary"
  columns { order_id text required }
  version = 1
  shape = "fnv1a:93ea2f35f00eaf57"
  consistency = Eventual
  feed = subscription
}
```

The `projection-owner` is sufficient authority for the catalog-bound read model; do
not also add an aggregate-local `projection orderSummary` clause. One owner may supply
several query contracts. For example, if the owner also owns `order_totals`, a second
read model with `targets = [ order_totals ]` resolves to the same
`order_summary_writer`. An inline owner is applied once per source event, not once per
query model.

The intentional language-5 form moves physical and lifecycle authority into
the catalog and leaves the read model as a typed query binding:

```text
language keiro-dsl 5

target order_summary {
  schema = "sales"
  table = "order_summary"
  reset = clear
}

rebuild-group reporting {
  targets = [ order_summary ]
  order = [ order_summary ]
}

projection-owner order_summary_writer {
  source = aggregate Orders
  delivery = subscription
  group = reporting
  targets = [ order_summary ]
  order = 10
  subscription = "orders-summary"
  dedup = "orders-summary-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel orderSummary {
  columns { order_id text required }
  version = 1
  shape = "fnv1a:784e511a19f74c58"
  freshness = immediate
  group = reporting
  targets = [ order_summary ]
}
```

`delivery` says when the owner applies events. `freshness` says what the query
does before executing SQL. The example deliberately chooses an asynchronous
subscription with `freshness = immediate`: it does not wait and may observe lag.
Choose `freshness = wait-for-head entire-log` only for an all-stream owner, or
`freshness = wait-for-head category "orders"` for an all-stream or matching
category owner. A head wait resolves the one compatible durable subscription
cursor from target ownership; inline owners and ambiguous cursor candidates are
rejected before generation. Caller-specific read-your-write remains a Haskell
`WaitForPosition` override with the command's returned position, not static DSL
source.

Candidate Language 5 requires exactly one `checkpoint-on-missing` choice for
each subscription owner and forbids the field on inline owners. Use
`from-beginning` to consume retained history, `from-current-head` to begin with
future events, or `fail` to require an operator-provisioned row. A replayable
owner of a `reset = clear` target cannot use `from-current-head`: clearing the
target and skipping history cannot reconstruct it.

Changing only the preamble does not invent ownership and will fail checking:
the author or a future upgrade tool must add the target, group, owner, source,
reset/replay policies, handler order, and query binding. Target declarations do
not create or migrate the table.

Migrate candidate sources mechanically:

| Previous candidate spelling | Language 5 spelling |
|---|---|
| projection-owner `feed = inline | subscription` | `delivery = inline | subscription` |
| read model `consistency = Eventual` plus either feed | `freshness = immediate`; remove read-model `feed` and `subscription` |
| read model `consistency = Strong` plus `scope` | `freshness = wait-for-head <scope>`; derive the cursor from its owner |
| standalone async read model | declare its target, group, and subscription projection owner |
| inner projection `consistency = ...` | put `freshness` on its read model; the implicit inline owner supports only `immediate` |

`keiro-dsl diff` enforces this table. Migrating `consistency = Strong` to
`freshness = immediate` is a breaking `QueryFreshnessChanged` finding because callers
lose the cursor-wait guarantee. A scope-preserving `wait-for-head <scope>` rewrite and
an `Eventual` to `immediate` rewrite report no policy change; strengthenings and head-
scope widenings across the migration are additive `CompatibilityStrengthened` findings.

These are candidate-only rewrites. Languages 1–4 retain their published
`feed`, `consistency`, and `scope` grammar and generated behavior.

Scaffolding emits one generated
`Generated.<Context>.ProjectionCatalog` facade. It validates the runtime
catalog, exposes catalog inventory/registration, typed inline views, and
group-scoped rebuild functions. `projectionCatalogQuerySupplies` exposes the checked
query-to-owner relation, while source-level inline views such as
`ordersInlineProjections` contain each owner handler once for command execution. The create-once
`<Context>.ProjectionCatalog.ProjectionCatalogHoles` module owns live and
replay apply functions, category decoders, and async idempotency functions;
regeneration preserves reviewed edits. An aggregate source reuses its generated
event codec. A category source receives a total replay decoder hole that must
classify every recorded event as irrelevant, decoded, or failed. Keep network
calls and other external side effects out of replay apply functions.

Mapped dependencies are inherited, not repeated. An inline projection on
`Orders` and every catalog owner with `source = aggregate Orders` consume the
complete transitive mapped closure of `Orders` private-event fields. Mapped
types used only by commands, registers, workqueues, or read-model query aliases
are excluded. Scaffold and diff output keep the typed handler relation separate
from the operational group/target/query-model relation because Keiro does not
inspect application SQL.

Changing an inherited mapped event wire identity changes the generated
aggregate-source fingerprint. Replayable owners invalidate the corresponding
catalog replay contract and rebuild group; live-only and inline handlers are
reported for recompilation/review without being described as replayable.
Category and all-history owners remain visible as unsupported heterogeneous
typed boundaries and never receive an invented mapped declaration.

See [Typed Specifications](typed-spec-toolchain.md#candidate-language-5-projection-catalogs)
for the complete syntax and validation rules.

## Register And Fence Catalog Groups

After validation, register the complete catalog once at application startup:

```haskell
Success validated -> do
  registration <- registerProjectionCatalog validated
  case registration of
    Left drift -> refuseStartup drift
    Right groups -> startProjectionWorkers groups
```

Registration persists one row per rebuild group and binds each query model to
that group in one transaction. Each group stores its canonical `slice-v3:`
fingerprint, so an unrelated additive group leaves existing registrations
unchanged. Repeating the same slice is idempotent; a changed or pre-canonical
stored slice is a typed startup error. Existing
unmanaged read models are migrated into deterministic
`$legacy-read-model:<name>` singleton groups and a matching live row can be
adopted by catalog registration.

Catalog evolution is explicit. Call `previewCatalogAdoption validated` to
classify catalog groups as new, unchanged, changed, or stale-format and to list
registered groups missing from the new catalog. To accept reviewed metadata
changes, call `adoptCatalogGroups validated groupIds`. Adoption locks every
requested group in sorted order, requires all of them to be registered and
`live`, except that a `failed` group with a stale-format fingerprint may be
adopted while it remains fenced. Canonical `failed` groups and all `rebuilding`
groups are still refused. Adoption updates slices and reconciles bound
query-model version, shape, and group metadata in one transaction, updating an
existing registration or inserting a missing one. `CatalogAdoptionResult`
reports each registration as adopted or inserted. It also reports and deletes an
`orphaned-old-name` row only when the preview named it, it is bound to a group
selected for adoption, and no registration anywhere in the complete catalog
claims the name; an out-of-scope move is therefore preserved. A registration
inserted for a failed stale-format group stays abandoned with its group fence.
Adoption does not rebuild or migrate application-owned rows; start a rebuild
separately when the catalog change invalidates persisted data.

Before crossing an identity or runner format boundary, completing or explicitly
abandoning every active catalog rebuild is recommended but not enforced. Migration
`0024` stamps a run begun before canonical slice identity with
`group_slice_fingerprint = '$pre-canonical'`. Such a run can never resume; it returns
`CatalogRebuildRunPreCanonical`. It remains inspectable and abandonable without a slice
comparison while it is the group's active run. Recover by abandoning it, previewing and
adopting the failed stale-format group while its fence stays active, then starting a fresh
rebuild. A fresh start accepts a `failed` group once its stored slice matches the catalog,
and only verified promotion returns it to `live`.

The same flow applies to an abandoned `slice-v1:` group. An active
`keiro/projection-replay/v3` run cannot resume under the v4 runner; complete it with the
old runtime or abandon it, then upgrade, preview, adopt, and start fresh. Changing only
the declaration order of a group's replayable projections also refuses resume of an
interrupted run, but it never refuses registration or a fresh rebuild, and the interrupted
run remains abandonable under the reordered catalog. Adoption changes Keiro metadata
only; it does not rebuild application rows.

Use `runCommandWithCatalogProjections` for inline application and
`applyAsyncProjectionFromCatalog` for async application. Both acquire shared
locks for the catalog-derived groups in stable identity order inside the same
transaction as the append or dedup/application work. When a group is rebuilding
or failed, the inline runner rolls back the event append and target SQL and the
async runner performs no dedup insert or target write. Treat the typed fenced
outcome as retryable unavailability; an async worker must not advance its
checkpoint for that event.

Start an offline rebuild with `beginGroupRebuild validated groupId request`.
Preparation holds the exclusive group lock while it:

- moves the group and all bound query models out of live service;
- clears every `ClearBeforeReplay` target through one quoted multi-table
  `TRUNCATE` without `CASCADE`;
- leaves every `PreserveAndReconcile` target untouched; and
- resets replayable async dedup identities and every persisted member of the
  catalog-declared subscriptions through Kiroku's public transaction API.

The reset report records the exact member keys that moved. If any declared
subscription has no persisted member, preparation returns a typed error and
condemns the transaction: the fence, target clear, dedup deletion, and any
already matched checkpoint resets all roll back together. Keiro never invents
consumer-group members or updates Kiroku's private table directly.

After replay and verification, promotion re-seeds each replayable async
projection's dedup identities over its durable redelivery window and advances
every persisted member of its declared subscription to the captured head. The
dedup backfill, checkpoint advance, completion proof, and group transition to
`live` commit in one transaction; a missing declared checkpoint condemns
promotion and leaves the run fenced and resumable.

An undeclared foreign-key reference therefore rejects and rolls back the whole
preparation instead of erasing external data. `abandonGroupRebuild` records
structured failure evidence and deliberately keeps the group fenced. Promotion
requires the opaque completion proof produced by the catalog replay runner; no
individual target or query binding can be promoted independently.

## Replay A Catalog Group

Declare application-owned verification on the rebuild group. Hook identity and
version are durable catalog facts; the transaction must only query rebuilt
state and return structured pass/fail evidence:

```haskell
RebuildGroupDeclaration
  { rebuildGroupId = orderReadGroup
  , orderedTargets = [orderSummaryTarget, orderAuditTarget]
  , verificationHooks =
      [ RebuildVerification
          { verificationId = "order-summary-shape"
          , verificationVersion = "v2"
          , verifyRebuild = verifyOrderSummary
          }
      ]
  , claimSite = orderReadGroupSite
  }
```

Start and drive the whole offline rebuild with only the validated catalog,
group identity, and operational options:

```haskell
let request =
      RebuildRequest
        { rebuildRunId = runId
        , requestedBy = operator
        , requestReason = reason
        , replayFrom = GlobalPosition 0
        }
    options =
      (defaultRebuildOptions request)
        { replayPageSize = 500
        , rebuildMetrics = Just metrics
        }

startCatalogRebuild validated orderReadGroup options
```

The runner captures one immutable global head after fencing writers. It scans
either `$all` or distinct categories in exclusive-cursor pages; multiple
categories are merged and applied in strictly ascending global-position order
across all of the group's sources. Replay adapters may rely on that order when
they read sibling targets. If buffered paging would regress or cannot advance
that order, the run fails with recorded invariant evidence instead of promoting.
Each bounded transaction commits target writes with source cursors and adapter
counters. Events appended after the captured head are never included.

`ReplayIrrelevant` still advances its source cursor and evaluation count.
`ReplayDecodeFailure` rolls back the whole current chunk, records the run,
source, projection, and position without recording payload, and leaves the
group fenced. Replay adapters must contain database-transactional behavior only:
never perform network calls or other external side effects from them.

Resume a failed or interrupted run with `resumeCatalogRebuild validated runId
options`. Page size may change. The group slice, source/codec facts, adapter order,
target/reset/query facts, verification identity/version, and runner format must
produce the exact stored contract fingerprint before any handler runs. Inspect
durable state at any time with `inspectCatalogRebuild runId`.

Promotion requires every source to prove exhaustion through the captured head,
every required adapter/source row to be complete, and every verification hook
to pass. Zero applies are valid when the adapters evaluated the selected history
and classified every event as irrelevant. Dedup rows are never substituted for
missing participation evidence.

The default page size is 500 and the persisted format is
`keiro/projection-replay/v4` with a `contract-v4:` fingerprint. The contract covers the
group slice plus replay-adapter source and projection identities in application order. A
run retains the whole `catalog-v4:` fingerprint as provenance and separately stores the
`slice-v3:` fingerprint used by its lifecycle fences. An unrelated catalog addition
therefore does not strand an active run, while a genuine change to that group or its
adapter application order still refuses resume. Optional metrics expose rebuild starts,
resumes, committed pages/events, failures, promotions, and page duration. Durable reports
also expose captured head, per-source cursor/target, evaluation/apply counts, and
verification evidence; neither surface contains raw event payloads.

## Inspect And Operate A Catalog

`Keiro.Projection.Catalog.Operations` is the operator-neutral boundary over the
same validated catalog. Construct it once with `projectionCatalogOperations`.
`catalogInventoryReport` and `previewGroupRebuild` are pure; the latter resolves
the selected group's targets, clear/preserve policies, sources, projections,
query models, subscription/dedup resets, verification hooks, lock scope, and
destructive status without touching PostgreSQL. `previewRegisteredGroupRebuild`
adds a read-only lifecycle lookup and an explicit
`registeredSliceMatches` result but does not acquire a fence or create a run.
Run inspection rejects a run recorded for a different current group slice.

The effectful actions include `previewCatalogAdoption`, `adoptCatalogGroups`,
`startGroupRebuild`, `inspectGroupRebuild`, `resumeGroupRebuild`, and
`abandonGroupRebuild`. Their callers provide only the
group or run identity and operational request; target, source, handler, reset,
subscription, and dedup lists cannot be overridden. Reports have stable,
versioned JSON envelopes:

- `keiro/catalog-inventory/v2`;
- `keiro/catalog-rebuild-preview/v2`;
- `keiro/catalog-registered-rebuild-preview/v2`; and
- `keiro/catalog-adoption-preview/v2`;
- `keiro/catalog-adoption-outcome/v2`; and
- `keiro/catalog-rebuild-run/v1`.

Every subscription in inventory and rebuild JSON includes
`checkpointOnMissing` with one of the stable values `FromBeginning`,
`FromCurrentHead`, or `FailIfMissing`.

The adapter intentionally has no parser, text renderer, confirmation policy, or
database credentials. `keiro-ops` owns those concerns and mounts the adapter
through `AppHooks.projectionCatalog`. In a candidate application binary,
`rebuild list|preview|start|status|resume|abandon|adopt` renders the same reports and
requires preview plus `--force` for mutations. Applications therefore do not
maintain a second rebuild map. An adoption preview shows the complete catalog but marks
each group, registration, and orphan as `adopt` or `skip` for the requested groups. It
warns by name when skipped drift will still block startup, and refuses a requested group
that the catalog does not contain before printing a force invocation. The
[Jitsurei rebuild rehearsal](../guides/run-and-operate-jitsurei.md#rehearse-a-catalog-rebuild)
shows the exact embedded commands against the disposable example database.

The hand-written `jitsureiProjectionCatalog` is executable adoption evidence:
one catalog drives managed inline application, async application, registration,
preview, a mixed clear/preserve rebuild, verification failure, fencing, repair,
resume, and promotion. Its application-owned replay adapter omits the
live-only side effect. The candidate-language-5
`keiro-dsl-conformance-projection-catalog` service supplies the generated path:
it imports only `Generated.CatalogDemo.ProjectionCatalog` and proves the same
inventory dimensions—four targets, mixed policies, a target dependency, two
atomic ordered groups, typed inline and async owners, a non-unit mapped query
contract, exact aggregate-source fingerprints, and a mapped workqueue beside the
read side. The integrated qualification keeps queue/query-only mappings out of
projection fingerprints while deriving event-only consumers for aggregate
sources.

## Migrate Existing Projection Fleets In Stages

Do not flip a preamble or replace all paths at once. Use this sequence:

1. Inventory every read model, physical table, live and replay handler,
   subscription/dedup identity, source, verification, and current rebuild
   procedure.
2. Group targets that must fence, reset, verify, and promote atomically.
3. Choose `ClearBeforeReplay` or `PreserveAndReconcile` for every target and
   `Replayable` or `LiveOnly` for every owner independently.
4. Choose `FromBeginning`, `FromCurrentHead`, or `FailIfMissing` for every
   subscription, accounting for whether its exact durable member rows already
   exist.
5. Add replay-specific transactional adapters that omit live-only effects and
   add application-owned verification for brownfield assumptions.
6. Build and validate the catalog while compatibility runners still operate;
   compare its inventory with the recorded fleet.
7. Switch startup registration and live selection to the catalog, then switch
   rebuild/operations, and adopt candidate language-5 generation only after the
   hand-written inventory is understood.
8. Retire unmanaged compatibility calls only after inventory and persisted
   baseline/diff evidence agree.

Validation is deliberately closed-world. It cannot discover an undeclared
table or prove what arbitrary SQL writes. Removing an owner while retaining its
target is a validation error; removing the entire target and owner together
requires `compareCatalogBaseline` or candidate-language-5 diff evidence because
the new catalog alone cannot prove that a declaration used to exist. Keiro never
creates or migrates application targets.

Changing only `checkpoint-on-missing` produces the dedicated
`CatalogCheckpointPolicyChanged` finding. The generated catalog and its
fingerprint change, so consumers must rebuild and deployment is
stop-the-world; the persisted subscription identity and existing checkpoint
rows remain compatible and unchanged.

## Initialize Legacy Metadata

The compatibility `keiro_read_models` table — which stores each model's version, shape hash,
status, and build timestamp — is created by `keiro-migrate`; see
[Database Migrations](migrations.md). Tests get it from the migrated template
database (the `keiro-test-support` `withMigratedSuite` fixture).

## Define A ReadModel

```haskell
data ReadModelBlueprint q r = ReadModelBlueprint
  { name :: Text
  , tableName :: Text
  , schema :: Text
  , version :: Int
  , shapeHash :: Text
  , cursorAuthority :: QueryCursorAuthority
  , query :: q -> Tx.Transaction r
  }

data QueryCursorAuthority
  = NoQueryCursor
  | DurableQueryCursor Text
```

`q` is your query input type. `r` is your result type. `schema` is the
PostgreSQL schema your read-model *data* table lives in (see
[Choosing Your Projection Schema](#choosing-your-projection-schema)); it is
entirely separate from Keiro's own `keiro` schema, where the `keiro_read_models`
registry lives.

Keiro still does not create your application read-model tables — your migrations
(or an opt-in helper) own the table *definitions*, indexes, and row codecs. What
Keiro now gives you is a first-class way to say *which schema* those tables live
in, and helpers to target it, instead of implicitly inheriting the store
connection's `search_path`. See [Migration Ownership](migration-ownership.md)
for where those migrations live and how to compose them with the framework
ledger.

Build new values with `immediateReadModel`, `headWaitingReadModel`, or
`positionWaitingReadModel`. Immediate inline models use `NoQueryCursor`; an async model
uses the durable subscription cursor resolved from its validated catalog owner. The two
waiting builders reject `NoQueryCursor`, and the position builder also rejects a missing
target. They return the existing `ReadModel q r` representation so registration and query
consumers stay compatible.

## Choosing Your Projection Schema

By default an unqualified `CREATE TABLE my_read_model (...)` lands in the store
connection's first `search_path` schema — which is kiroku's `kiroku` event-store
schema — co-mingling your application data with the event store. To place your
read-model and projection tables in a schema you choose, use the `schema` field
on `ReadModel` together with the helpers in the `Keiro.Connection` module:

```haskell
import Keiro.Connection
  ( qualifyTable          -- schema -> table -> "schema"."table"
  , qualifiedTableName    -- imported from Keiro.ReadModel: a ReadModel's "schema"."table"
  , withProjectionSchema  -- add a projection schema to a store connection's extraSearchPath
  , keiroConnectionSettings  -- kiroku defaults + a projection schema on extraSearchPath
  , ensureProjectionSchema   -- opt-in CREATE SCHEMA IF NOT EXISTS, for dev/tests/examples
  )
import Keiro.ReadModel
  ( QueryCursorAuthority (NoQueryCursor)
  , ReadModel
  , ReadModelBlueprint (..)
  , immediateReadModel
  , qualifiedTableName
  )

orderSummary :: ReadModel OrderId (Maybe OrderSummary)
orderSummary =
  immediateReadModel
    ReadModelBlueprint
      { name = "order-summary"
      , tableName = "order_summary"
      , schema = "app_reads"          -- your chosen schema, NOT kiroku
      , version = 1
      , shapeHash = "order-summary-v1"
      , cursorAuthority = NoQueryCursor
      , query = \oid -> Tx.statement (orderIdText oid) selectOrderSummaryStmt
      }
```

Qualify every DDL and DML statement for that table against the schema. The
canonical reference is `qualifiedTableName orderSummary` (equal to
`qualifyTable "app_reads" "order_summary"`, i.e. `"app_reads"."order_summary"`),
interpolated into your SQL, so reads and writes resolve correctly regardless of
`search_path`:

```haskell
selectOrderSummaryStmt =
  preparable
    ("SELECT ... FROM " <> qualifiedTableName orderSummary <> " WHERE order_id = $1")
    encoder
    decoder
```

Open the store so the schema also resolves on the pool, and create it (in
development, tests, or worked examples — production DDL belongs in your
migrations):

```haskell
-- kiroku defaults with your projection schema on extraSearchPath;
-- the store `schema` stays "kiroku" (it also drives the NOTIFY channel).
Store.withStore (keiroConnectionSettings connString "app_reads") $ \store ->
  Store.runStoreIO store $ do
    ensureProjectionSchema "app_reads"           -- opt-in CREATE SCHEMA
    Store.runTransaction createOrderSummaryTable  -- your qualified CREATE TABLE
```

Keiro's own framework metadata (`keiro_read_models`, `keiro_projection_dedup`)
stays in the `keiro` schema and is unaffected by your choice.

## Query Freshness

```haskell
data QueryFreshness
  = Immediate
  | WaitForHead HeadScope
  | WaitForPosition PositionWaitOptions

data HeadScope
  = EntireVisibleLog
  | CategoryVisibleHead Text
```

Use:

- `Immediate` to execute after schema/liveness validation without polling. It works for
  inline and async models and does not require a cursor.
- `WaitForHead EntireVisibleLog` to capture the visible whole-store head once and wait
  until an all-stream owner's durable cursor reaches it.
- `WaitForHead (CategoryVisibleHead category)` to capture that category's visible head
  once and wait on an all-stream or same-category owner cursor.
- `WaitForPosition options` when the caller has a concrete `GlobalPosition`, commonly the
  position returned by its command, and wants an async projection to catch up to it.

`WaitForHead` is a bounded captured-head wait, not a claim of linearizability. The head is
captured once at query start. A model fed from multiple categories should use an explicit
position target or an all-stream owner with `EntireVisibleLog`. The current whole-store
head implementation remains the visible-head seam owned by Plan 238; final tail-GC
acceptance is gated on that plan.

`PositionWaitOptions`:

```haskell
data PositionWaitOptions = PositionWaitOptions
  { target :: Maybe GlobalPosition
  , timeoutMicros :: Int
  , pollMicros :: Int
  }
```

Truthful `WaitForPosition` requires `target = Just position`. A missing target returns
`ReadModelMissingPosition`; a wait on a cursorless model returns
`ReadModelMissingCursor`. Catalog construction catches owner-level missing or ambiguous
cursor capabilities earlier with deterministic validation diagnostics.

### 0.12 compatibility and 0.13 removal

The physical `ReadModel` record and legacy vocabulary remain source-compatible for the
0.12 migration window. New code should migrate mechanically:

| 0.11 API | Exact behavior retained in 0.12 | Truthful replacement |
|---|---|---|
| `Eventual` | Execute immediately. | `Immediate` |
| `Strong` + `EntireLog` | Capture the visible whole-store head and poll the named cursor. | `WaitForHead EntireVisibleLog` |
| `Strong` + `CategoryHead c` | Capture category `c`'s visible head and poll the named cursor. | `WaitForHead (CategoryVisibleHead c)` |
| `PositionWait options` | Wait for `target`; historical `Nothing` executes immediately. | `WaitForPosition options` with a concrete target |
| direct `ReadModel` construction | Existing fields and positional construction compile unchanged. | `ReadModelBlueprint` plus a truthful builder |
| `runQueryWith` | Override the legacy mode. | `runQueryWithFreshness` |
| `defaultStrongWaitOptions` | Five-second timeout, 10ms poll. | `defaultHeadWaitOptions` |

The exact-behavior column applies to models with real durable cursors. A cursorless model
built with `NoQueryCursor` fails fast with `ReadModelMissingCursor` through `waitFor` and
deprecated `Strong` or targeted `PositionWait` overrides, exactly as it does through
`runQueryWithFreshness`; no 0.11 source can construct the private cursorless
compatibility representation.

`ConsistencyMode`, `StrongScope`, their constructors, `subscriptionName`,
`defaultConsistency`, `strongScope`, `defaultStrongWaitOptions`, and `runQueryWith` are
deprecated and scheduled for removal in 0.13. To migrate a direct record, move its
identity/table/query fields into `ReadModelBlueprint`, use `NoQueryCursor` for inline
models or `DurableQueryCursor subscription` for async models, then choose the builder
matching the old default. Use `runQueryWithFreshness` for per-call overrides.

## Querying

```haskell
runQuery readModel input
runQueryWithFreshness freshness readModel input
```

Register each model once when its projection starts:

```haskell
registerReadModel
  (orderSummary ^. #name)
  (orderSummary ^. #version)
  (orderSummary ^. #shapeHash)
```

Queries never create registry rows. Before running the query transaction, Keiro
loads the registered metadata and checks:

- stored version equals the read model's version;
- stored shape hash equals the read model's shape hash;
- status is `Live`.

Failures are returned as `ReadModelError`; an unknown name returns
`ReadModelUnregistered` without changing the registry.

## Inline Projections

Inline projections run inside the command append transaction.

```haskell
data InlineProjection co = InlineProjection
  { name :: Text
  , apply :: co -> RecordedEvent -> Tx.Transaction ()
  }
```

`apply` receives the decoded event together with its per-event `RecordedEvent`,
so a projection can read event metadata (actor, source event id, stream version,
global position) when writing the read-model row.

Use `runCommandWithProjections`:

```haskell
runCommandWithProjections
  defaultRunCommandOptions
  orderEventStream  -- ValidatedEventStream
  orderStream
  command
  [orderSummaryProjection]
```

If projection SQL fails or condemns the transaction, the append rolls back.
This is the path for strongly consistent read-after-write behavior.

See [Project Read Models](../guides/project-read-models.md) for the
`jitsurei_order_summary` table, inline projection, and `ReadModel` query backed
by `jitsurei-test`.

## Async Projections

```haskell
data AsyncProjection = AsyncProjection
  { name :: Text
  , readModelName :: Text
  , subscriptionName :: Text
  , applyRecorded :: RecordedEvent -> Tx.Transaction ()
  , idempotencyKey :: RecordedEvent -> EventId
  }
```

`applyAsyncProjection` runs the projection's transaction body for one recorded
event. Worker wiring is application-owned and typically comes from a Kiroku /
Shibuya subscription source. It returns `AsyncApplied`, `AsyncDuplicate`, or
`AsyncFenced`. The worker must not checkpoint an `AsyncFenced` event; park or
fail the delivery and retry after the model is promoted. The fence is checked
inside the same transaction as the dedup insert and model update.

Async delivery is at least once. An `idempotencyKey` plus Keiro's dedup table
makes projection application exactly once per retained dedup window, including
across offline catalog rebuilds whose promotion re-seeds dedup and advances the
declared checkpoints. Idempotent handler SQL remains recommended defense in
depth because operators may prune dedup rows once events leave the redelivery
window.
The usual table shape includes a unique `source_event_id` column:

```sql
INSERT INTO order_audit (source_event_id, order_id, message)
VALUES ($1, $2, $3)
ON CONFLICT (source_event_id) DO NOTHING;
```

## Legacy Rebuild Lifecycle

The supported offline workflow in `Keiro.ReadModel.Rebuild` is:

1. Register the model at projection startup.
2. Call `startRebuild model projectionNames replayFrom`. One transaction marks
   the model `Rebuilding`, fences normal writers, truncates the model table,
   clears only those projections' dedup keys, and, for a cursor-bearing model,
   uses Kiroku's public reset API to move all existing members of its subscription
   to the replay point. A cursorless model has no checkpoint to reset, so this
   step is skipped; pair that inline-only shape with an empty projection-name list.
3. Replay events through `applyAsyncProjectionUnfenced`. Do not use that entry
   point in normal workers.
4. After replay and application-specific verification, call
   `finishRebuild model projectionNames replayFrom`. It refuses to promote a
   rebuild that applied nothing even though the log contains replayable events.
5. On failure, call `abandonRebuild` and keep the partial model offline while it
   is repaired or restored.

These single-read-model functions are an unmanaged compatibility path. They
accept caller-supplied projection-name lists and cannot coordinate several
targets. Keep them while migrating existing applications; new production code
should register a validated catalog and use the group lifecycle above. The
lower-level `rebuild` and `promote` functions additionally bypass reset and
promotion safeguards.

## Errors

`ReadModelError` values:

- `ReadModelStaleSchema`: code and stored metadata disagree.
- `ReadModelWaitTimeout`: position wait timed out.
- `ReadModelMissingCursor`: any wait was requested for a cursorless model, whether
  through truthful freshness, a deprecated waiting override, or `waitFor`.
- `ReadModelMissingPosition`: `WaitForPosition` omitted its required target.
- `ReadModelNotLive`: metadata status is not `Live`.
- `ReadModelUnregistered`: startup did not register this model name.

Treat stale schema and non-live errors as deployment/rebuild coordination
signals, not transient query misses.
