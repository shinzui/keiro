# Process Managers And Timers

A process manager reacts to one stream and emits commands to another stream.
`jitsurei` uses this to model fulfillment: when an order receives
`PaymentApproved`, the fulfillment manager records that it observed the payment
and emits `MarkPacked` to the order stream.

The manager lives in
[`../../jitsurei/src/Jitsurei/FulfillmentProcess.hs`](../../jitsurei/src/Jitsurei/FulfillmentProcess.hs).
It has its own stream family, `fulfillment-<order-id>`, and its own small event
stream:

```haskell
data FulfillmentCommand = ObserveFulfillmentEvent OrderId Text
data FulfillmentEvent = FulfillmentObserved OrderId Text
```

The process manager's `handle` function is pure. It always advances the manager
state stream with an observation event. For `PaymentApproved`, it also returns a
target command:

```haskell
PMCommand
  { target = orderCommandStream orderId
  , command = MarkPacked orderId
  }
```

`runProcessManagerOnce` receives the recorded source event and the decoded
domain event. Keiro derives deterministic event ids from manager name,
correlation id, source event id, and command index. If the same source event is
delivered again, the manager reports duplicate results rather than appending a
second manager event or packing command.

The test in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs) first places and
pays an order, reads the recorded `PaymentApproved` event from Kiroku, runs the
manager, then runs it a second time and asserts `PMStateDuplicate` plus
`PMCommandDuplicate`.

Timers are database-backed scheduled actions. The timer example lives in
[`../../jitsurei/src/Jitsurei/Timers.hs`](../../jitsurei/src/Jitsurei/Timers.hs).
It builds a payment-timeout `TimerRequest` and a worker that marks a claimed
timer fired.

The example uses `Data.TypeID.V7` from `mmzk-typeid` to derive UUID values for
timer and event fixtures. Do not use the `uuid` package as if it generated
UUIDv7 values; it does not provide that capability here.

Local tests schedule the timer with `scheduleTimerTx`, call
`runPaymentTimeoutWorker`, and assert that a due row was claimed. Production
workers usually loop around `runTimerWorker`, append or submit a command from
the timer payload, and return the event id that represents successful firing.
