# Project Read Models

An event stream is excellent for writes and audit history, but most product
screens need direct queries. `jitsurei` builds an inline read model named
`jitsurei_order_summary` that stores one row per order with SKU, quantity,
status, and the last global event position it observed.

If you are still deciding how the view should be delivered, start with
[Choosing A Projection](choosing-a-projection.md). The focused
[Inline Projections](inline-projections.md) and
[Asynchronous Projections](asynchronous-projections.md) guides explain each
handler path, while [Offline Projection Rebuilds](offline-projection-rebuilds.md)
explains the full lifecycle; this guide shows all three operating from one
catalog.

The code is in
[`../../jitsurei/src/Jitsurei/ReadModels.hs`](../../jitsurei/src/Jitsurei/ReadModels.hs).
The tables live in the example's own `jitsurei` schema (chosen via the
`ReadModel` `schema` field and `Keiro.Connection.qualifyTable`), not in the
`kiroku` event-store schema. The initializer is plain application-owned Hasql
transaction code. It creates the summary root, a foreign-key line child, an
async audit target, and an unowned live-side-effect evidence table:

```haskell
initializeOrderSummaryTable :: Tx.Transaction ()
```

The read model value describes metadata, its data schema, and query behavior:

```haskell
orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
-- with schema = "jitsurei"; every DDL/DML is qualified jitsurei.jitsurei_order_summary
```

`ReadModel.version` and `shapeHash` let Keiro fail reads when the code and
stored metadata disagree. `ReadModel.schema` names the PostgreSQL schema the
read-model *data* table lives in — see
[Choosing Your Projection Schema](../user/read-models-and-projections.md#choosing-your-projection-schema).
The hand-written Jitsurei value still exercises the 0.12 source-compatibility
record. New code expresses the same truthful contract with
`immediateReadModel (ReadModelBlueprint { cursorAuthority = NoQueryCursor, ... })`:
its inline projection commits with the command, and the query executes without
polling because there is no asynchronous subscription cursor. The deprecated
`defaultConsistency = Eventual` and `strongScope = EntireLog` fields are retained
only so 0.11 direct-record callers compile during the 0.12 migration window.

The live handler is an `InlineProjection OrderEvent`, but it is not assembled
through an independent startup list:

```haskell
orderSummaryInlineProjection :: InlineProjection OrderEvent
orderProjectionSet :: ProjectionSet OrderEvent
jitsureiProjectionCatalog :: ValidatedProjectionCatalog
```

`OrderPlaced` inserts or replaces the summary row. Later events update the
status to `paid`, `packed`, `shipped`, or `cancelled`. The projection receives
the decoded event and the Kiroku `RecordedEvent`, so it can store the global
position (`recorded.globalPosition`) that produced the row. Its live body also
writes test-observable side-effect evidence; its explicit replay adapter applies
only database reconstruction, so rebuild cannot repeat that live-only action.

Run the command through the typed catalog source view:

```haskell
runCommandWithCatalogProjections
  defaultRunCommandOptions
  orderEventStream  -- ValidatedOrderEventStream
  (orderStream orderId)
  command
  jitsureiProjectionCatalog
  orderProjectionSet
```

If the append fails, the projection does not run. If the projection SQL fails,
the append transaction is condemned too. That gives read-after-write behavior
for screens that need the query row immediately after a successful command. The
same transaction locks the catalog's rebuild group; a rebuilding or failed group
returns `ProjectionCommandFenced` and rolls back both event and target writes.

The catalog declares one mixed-policy `jitsurei-order-reporting` group. The
summary root is `PreserveAndReconcile`; the line and async-audit targets are
`ClearBeforeReplay`. Startup registration, managed inline application, async
application, inventory/preview, source selection, resets, verification, and the
fixed-head rebuild all derive from that value. The acceptance test preserves a
brownfield root with no event history, reconstructs the derived tables, blocks
promotion on an unsafe retained row, proves writes remain fenced during repair,
resumes the same run, and verifies the live-only side effect was not replayed.

Candidate language 5 supplies the generated counterpart in
`keiro-dsl/test/conformance-projection-catalog`: its program imports one
`Generated.CatalogDemo.ProjectionCatalog` facade and checks the same inventory
dimensions instead of reconstructing lists from generated leaf modules. Its
projection owners declare `delivery = inline | subscription`; its query models
declare `freshness = immediate | wait-for-head ...`. Generated code derives any
durable cursor from the validated owner instead of accepting one on the query.

Local tests initialize framework and application tables through
[`../../jitsurei/src/Jitsurei/Database.hs`](../../jitsurei/src/Jitsurei/Database.hs):

```haskell
initializeJitsureiTables :: (Store :> es) => Eff es ()
```

Production services should put the application table in their migration system
and run Keiro's framework migrations before startup. See
[Rehearse A Catalog Rebuild](run-and-operate-jitsurei.md#rehearse-a-catalog-rebuild)
for the exact read-only inventory/preview commands, force boundary, and
failure-recovery shape in the embedded Jitsurei operator binary.
