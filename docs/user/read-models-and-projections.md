# Read Models And Projections

Read models are query-optimized views derived from the event log. Keiro provides
metadata, consistency helpers, inline projection support, and at-least-once async
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
        inventory = catalogInventory validated
        fingerprint = catalogFingerprint validated
    registerApplicationReadSide inventory
    runOrderWriter liveOrderHandlers
```

The `ValidatedProjectionCatalog` constructor is hidden. Use
`useProjectionCatalogM` when registration is effectful; it does not invoke the
callback after failed validation. Inventory rendering and SHA-256 fingerprints
are stable for the same semantic declarations regardless of input-list order.
Handler closures are excluded from the fingerprint.

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
  feed = subscription
  group = reporting
  targets = [ order_summary ]
  order = 10
  subscription = "orders-summary"
  dedup = "orders-summary-v1"
  replay = explicit
}

readmodel orderSummary {
  columns { order_id text required }
  version = 1
  shape = "fnv1a:784e511a19f74c58"
  consistency = Eventual
  feed = subscription
  group = reporting
  targets = [ order_summary ]
}
```

Changing only the preamble does not invent ownership and will fail checking:
the author or a future upgrade tool must add the target, group, owner, source,
reset/replay policies, handler order, and query binding. Target declarations do
not create or migrate the table.

Scaffolding emits one generated
`Generated.<Context>.ProjectionCatalog` facade. It validates the runtime
catalog, exposes catalog inventory/registration, typed inline views, and
group-scoped rebuild functions. The create-once
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
that group in one transaction. Repeating the same fingerprint is idempotent; a
different fingerprint for an existing group is a typed startup error. Existing
unmanaged read models are migrated into deterministic
`$legacy-read-model:<name>` singleton groups and a matching live row can be
adopted by catalog registration.

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
- resets only the replayable async dedup and subscription identities derived
  from that group in the validated catalog.

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
categories are merged by global position. Each bounded transaction commits
target writes with source cursors and adapter counters. Events appended after
the captured head are never included.

`ReplayIrrelevant` still advances its source cursor and evaluation count.
`ReplayDecodeFailure` rolls back the whole current chunk, records the run,
source, projection, and position without recording payload, and leaves the
group fenced. Replay adapters must contain database-transactional behavior only:
never perform network calls or other external side effects from them.

Resume a failed or interrupted run with `resumeCatalogRebuild validated runId
options`. Page size may change. The catalog, source/codec facts, adapter order,
target/reset/query facts, verification identity/version, and runner format must
produce the exact stored contract fingerprint before any handler runs. Inspect
durable state at any time with `inspectCatalogRebuild runId`.

Promotion requires every source to prove exhaustion through the captured head,
every required adapter/source row to be complete, and every verification hook
to pass. Zero applies are valid when the adapters evaluated the selected history
and classified every event as irrelevant. Dedup rows are never substituted for
missing participation evidence.

The default page size is 500 and the persisted format is
`keiro/projection-replay/v1`. Optional metrics expose rebuild starts, resumes,
committed pages/events, failures, promotions, and page duration. Durable reports
also expose captured head, per-source cursor/target, evaluation/apply counts,
and verification evidence; neither surface contains raw event payloads.

## Inspect And Operate A Catalog

`Keiro.Projection.Catalog.Operations` is the operator-neutral boundary over the
same validated catalog. Construct it once with `projectionCatalogOperations`.
`catalogInventoryReport` and `previewGroupRebuild` are pure; the latter resolves
the selected group's targets, clear/preserve policies, sources, projections,
query models, subscription/dedup resets, verification hooks, lock scope, and
destructive status without touching PostgreSQL. `previewRegisteredGroupRebuild`
adds a read-only lifecycle lookup and an explicit
`registeredFingerprintMatches` result but does not acquire a fence or create a
run. Run inspection also rejects a run recorded for a different catalog
fingerprint.

The effectful actions are `startGroupRebuild`, `inspectGroupRebuild`,
`resumeGroupRebuild`, and `abandonGroupRebuild`. Their callers provide only the
group or run identity and operational request; target, source, handler, reset,
subscription, and dedup lists cannot be overridden. Reports have stable,
versioned JSON envelopes:

- `keiro/catalog-inventory/v1`;
- `keiro/catalog-rebuild-preview/v1`;
- `keiro/catalog-registered-rebuild-preview/v1`; and
- `keiro/catalog-rebuild-run/v1`.

The adapter intentionally has no parser, text renderer, confirmation policy, or
database credentials. `keiro-ops` owns those concerns and mounts the adapter
through `AppHooks.projectionCatalog`. In a candidate application binary,
`rebuild list|preview|start|status|resume|abandon` renders the same reports and
requires preview plus `--force` for mutations. Applications therefore do not
maintain a second rebuild map. The
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
4. Add replay-specific transactional adapters that omit live-only effects and
   add application-owned verification for brownfield assumptions.
5. Build and validate the catalog while compatibility runners still operate;
   compare its inventory with the recorded fleet.
6. Switch startup registration and live selection to the catalog, then switch
   rebuild/operations, and adopt candidate language-5 generation only after the
   hand-written inventory is understood.
7. Retire unmanaged compatibility calls only after inventory and persisted
   baseline/diff evidence agree.

Validation is deliberately closed-world. It cannot discover an undeclared
table or prove what arbitrary SQL writes. Removing an owner while retaining its
target is a validation error; removing the entire target and owner together
requires `compareCatalogBaseline` or candidate-language-5 diff evidence because
the new catalog alone cannot prove that a declaration used to exist. Keiro never
creates or migrates application targets.

## Initialize Legacy Metadata

The compatibility `keiro_read_models` table — which stores each model's version, shape hash,
status, and build timestamp — is created by `keiro-migrate`; see
[Database Migrations](migrations.md). Tests get it from the migrated template
database (the `keiro-test-support` `withMigratedSuite` fixture).

## Define A ReadModel

```haskell
data ReadModel q r = ReadModel
  { name :: Text
  , tableName :: Text
  , schema :: Text
  , subscriptionName :: Text
  , version :: Int
  , shapeHash :: Text
  , defaultConsistency :: ConsistencyMode
  , strongScope :: StrongScope
  , query :: q -> Tx.Transaction r
  }
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
import Keiro.ReadModel (ReadModel (..), qualifiedTableName)

orderSummary :: ReadModel OrderId (Maybe OrderSummary)
orderSummary =
  ReadModel
    { name = "order-summary"
    , tableName = "order_summary"
    , schema = "app_reads"          -- your chosen schema, NOT kiroku
    , subscriptionName = "order-summary-inline"
    , version = 1
    , shapeHash = "order-summary-v1"
    , defaultConsistency = Eventual
    , strongScope = EntireLog
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

## Consistency Modes

```haskell
data ConsistencyMode
  = Strong
  | Eventual
  | PositionWait PositionWaitOptions

data StrongScope
  = EntireLog
  | CategoryHead Text
```

Use:

- `Strong` for an async model that should wait for its subscription cursor to
  reach the log head captured at query start. Set `strongScope = EntireLog` only
  when the subscription observes the whole log; category subscriptions should
  use `CategoryHead category` so unrelated categories cannot cause a timeout.
- `Eventual` for async models where stale reads are acceptable.
- `PositionWait` when a caller has a target `GlobalPosition` and wants to wait
  until the subscription has processed at least that position.

Inline projections commit with their command and should normally use
`Eventual`: there is no asynchronous cursor to wait for. A model fed from
multiple categories should use an explicit `PositionWait` target or an
all-stream subscription with `EntireLog`.

`PositionWaitOptions`:

```haskell
data PositionWaitOptions = PositionWaitOptions
  { target :: Maybe GlobalPosition
  , timeoutMicros :: Int
  , pollMicros :: Int
  }
```

If `target = Nothing`, `PositionWait` does not wait.

## Querying

```haskell
runQuery readModel input
runQueryWith consistency readModel input
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

Async projections are at-least-once in v1. Make every async handler idempotent.
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
   clears only those projections' dedup keys, and resets the subscription cursor.
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
- `ReadModelNotLive`: metadata status is not `Live`.
- `ReadModelUnregistered`: startup did not register this model name.

Treat stale schema and non-live errors as deployment/rebuild coordination
signals, not transient query misses.
