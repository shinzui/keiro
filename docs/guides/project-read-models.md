# Project Read Models

An event stream is excellent for writes and audit history, but most product
screens need direct queries. `jitsurei` builds an inline read model named
`jitsurei_order_summary` that stores one row per order with SKU, quantity,
status, and the last global event position it observed.

The code is in
[`../../jitsurei/src/Jitsurei/ReadModels.hs`](../../jitsurei/src/Jitsurei/ReadModels.hs).
The table lives in the example's own `jitsurei` schema (chosen via the
`ReadModel` `schema` field and `Keiro.Connection.qualifyTable`), not in the
`kiroku` event-store schema. The table initializer is plain Hasql transaction
code that creates the schema and the schema-qualified table:

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
[Choosing Your Projection Schema](../user/read-models-and-projections.md#choosing-your-projection-schema). `defaultConsistency = Strong` is appropriate here
because this model is updated inline in the same transaction as the command
append.

The projection is an `InlineProjection OrderEvent`:

```haskell
orderSummaryInlineProjection :: InlineProjection OrderEvent
```

`OrderPlaced` inserts or replaces the summary row. Later events update the
status to `paid`, `packed`, `shipped`, or `cancelled`. The projection receives
the decoded event and the Kiroku `RecordedEvent`, so it can store the global
position (`recorded.globalPosition`) that produced the row.

Run the command and projection together with:

```haskell
runCommandWithProjections
  defaultRunCommandOptions
  orderEventStream  -- ValidatedOrderEventStream
  (orderStream orderId)
  command
  [orderSummaryInlineProjection]
```

If the append fails, the projection does not run. If the projection SQL fails,
the append transaction is condemned too. That gives read-after-write behavior
for screens that need the query row immediately after a successful command.

Local tests initialize framework and application tables through
[`../../jitsurei/src/Jitsurei/Database.hs`](../../jitsurei/src/Jitsurei/Database.hs):

```haskell
initializeJitsureiTables :: (Store :> es) => Eff es ()
```

Production services should put the application table in their migration system
and run Keiro's framework migrations before startup. See
[Run And Operate Jitsurei](run-and-operate-jitsurei.md) for the operational
shape.
