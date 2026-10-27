---
type: Tutorial
title: Order Fulfillment Overview
description: Follow the Jitsurei order-fulfillment system from commands through projections and background work.
docId: DOC-2
tags: [keiro, jitsurei, order-fulfillment, tutorial]
generated:
  by: process:codex-cli
  at: 2026-10-11T21:11:39Z
timestamp: 2026-10-27T21:15:00Z
---

# Order Fulfillment Overview

For commands run from this repository, enter `nix develop` first. It supplies
the project compiler, PostgreSQL, and Z3 used by the tests.

The worked example deliberately demonstrates an atomic inline order summary.
For a new application, default query models to asynchronous delivery and use
[post-commit read-your-write](asynchronous-projections.md#read-your-write-after-commit)
when needed. Keep inline state only for a specified atomic invariant and measure
its cost to unrelated writers in the same store.

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
The core command type uses record payloads. That keeps examples close to
production code, where commands and events accumulate fields over time and
where labels make JSON codecs, logs, and tests easier to read.

```haskell
data OrderCommand
  = PlaceOrder PlaceOrderData
  | ApprovePayment ApprovePaymentData
  | MarkPacked MarkPackedData
  | ShipOrder ShipOrderData
  | CancelOrder CancelOrderData

data PlaceOrderData = PlaceOrderData
  { orderId :: OrderId
  , sku :: Sku
  , quantity :: Quantity
  }
```

The matching events are `OrderPlaced`, `PaymentApproved`, `OrderPacked`,
`OrderShipped`, and `OrderCancelled`, and they also carry record payloads such
as `OrderPlacedData`. `OrderState` is the replayed aggregate state:
`NotStarted`, `Placed`, `Paid`, `Packed`, `Shipped`, or `Cancelled`.

The guide code is split by responsibility:

- [`Jitsurei.OrderStream`](../../jitsurei/src/Jitsurei/OrderStream.hs) defines
  the Keiki transducer, raw Keiro `EventStream` definition, validated stream
  value, stream naming, and event codec.
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

The suite covers the command path, coordinated and versioned catalog rebuilds,
repair/resume, dispatch, timers, snapshots, and durable workflows. If a guide
claim is not backed by a test or a linked `jitsurei/src/` module, treat that as a
documentation bug.
