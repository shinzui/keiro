# Order Fulfillment Overview

`jitsurei` is a small order-fulfillment application built to demonstrate Keiro
as application code would use it. The example has one aggregate stream per
order, an inline read model for queryable order summaries, a fulfillment process
manager that reacts to payment approval, a durable payment-timeout timer, and an
optional snapshot policy.

The domain is intentionally ordinary. A customer places an order for a SKU and
quantity. Payment approval moves the order into a paid state. Fulfillment packs
the order, shipping marks it shipped, and cancellation is only valid before
payment. That gives the guides enough real state transitions to show command
acceptance and rejection without hiding the Keiro APIs behind a web framework.

The domain types live in
[`../../jitsurei/src/Jitsurei/Domain.hs`](../../jitsurei/src/Jitsurei/Domain.hs).
The core command type is:

```haskell
data OrderCommand
  = PlaceOrder OrderId Sku Quantity
  | ApprovePayment OrderId PaymentRef
  | MarkPacked OrderId
  | ShipOrder OrderId Carrier TrackingId
  | CancelOrder OrderId Text
```

The matching events are `OrderPlaced`, `PaymentApproved`, `OrderPacked`,
`OrderShipped`, and `OrderCancelled`. `OrderState` is the replayed aggregate
state: `NotStarted`, `Placed`, `Paid`, `Packed`, `Shipped`, or `Cancelled`.

The guide code is split by responsibility:

- [`Jitsurei.OrderStream`](../../jitsurei/src/Jitsurei/OrderStream.hs) defines
  the Keiki transducer, Keiro `EventStream`, stream naming, and event codec.
- [`Jitsurei.ReadModels`](../../jitsurei/src/Jitsurei/ReadModels.hs) defines
  the `jitsurei_order_summary` table projection and query.
- [`Jitsurei.FulfillmentProcess`](../../jitsurei/src/Jitsurei/FulfillmentProcess.hs)
  defines the process manager that turns `PaymentApproved` into `MarkPacked`.
- [`Jitsurei.Timers`](../../jitsurei/src/Jitsurei/Timers.hs) defines a durable
  payment-timeout timer request and worker.
- [`Jitsurei.Database`](../../jitsurei/src/Jitsurei/Database.hs) collects local
  schema initialization for tests and demos.

The proof is in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs). It runs against an
ephemeral PostgreSQL database and covers codec evolution, command execution,
read-model projection, snapshots, process-manager idempotency, and timers.

Run the example tests from the repository root:

```bash
cabal test jitsurei-test
```

You should see seven examples pass. If a guide claim is not backed by one of
those tests or by a linked `jitsurei/src/` module, treat that as a documentation
bug.
