# Project Read Models

An event stream is excellent for writes and audit history, but most product
screens need direct queries. `jitsurei` builds an inline read model named
`jitsurei_order_summary` that stores one row per order with SKU, quantity,
status, and the last global event position it observed.

The code is in
[`../../jitsurei/src/Jitsurei/ReadModels.hs`](../../jitsurei/src/Jitsurei/ReadModels.hs).
The table initializer is plain Hasql transaction code:

```haskell
initializeOrderSummaryTable :: Tx.Transaction ()
```

The read model value describes metadata and query behavior:

```haskell
orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
```

`ReadModel.version` and `shapeHash` let Keiro fail reads when the code and
stored metadata disagree. `defaultConsistency = Strong` is appropriate here
because this model is updated inline in the same transaction as the command
append.

The projection is an `InlineProjection OrderEvent`:

```haskell
orderSummaryInlineProjection :: InlineProjection OrderEvent
```

`OrderPlaced` inserts or replaces the summary row. Later events update the
status to `paid`, `packed`, `shipped`, or `cancelled`. The projection receives
the Kiroku `AppendResult`, so it can store the global position that produced the
row.

Run the command and projection together with:

```haskell
runCommandWithProjections
  defaultRunCommandOptions
  orderEventStream
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
