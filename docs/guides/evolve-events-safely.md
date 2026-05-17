# Evolve Events Safely

Keiro stores events as JSON payloads plus an event type tag and metadata. The
`Codec OrderEvent` in
[`../../jitsurei/src/Jitsurei/OrderStream.hs`](../../jitsurei/src/Jitsurei/OrderStream.hs)
is the boundary between the stored shape and the Haskell domain type.

The codec declares every legal event type, chooses the tag for each domain
event, writes the current schema version, and supplies encode/decode functions:

```haskell
orderCodec :: Codec OrderEvent
orderCodec = Codec
  { eventTypes = "OrderPlaced" :| ["PaymentApproved", "OrderPacked", "OrderShipped", "OrderCancelled"]
  , schemaVersion = 2
  , encode = ...
  , decode = parseOrderEvent
  , upcasters = [(1, upcastOrderPlacedV1)]
  }
```

The current `OrderPlaced` payload uses `quantity`. Version 1 used `qty`. The
upcaster reads the old field, supplies a default SKU when the old payload does
not have one, and returns the current version-2 JSON shape:

```haskell
upcastOrderPlacedV1 :: Value -> Either Text Value
```

During hydration, `runCommand` calls `decodeRecorded`. That function checks the
stored event type tag first, reads `schemaVersion` from metadata, runs each
needed upcaster in order, and only then decodes the current payload. Keiro does
not skip bad stored events because command decisions must be based on the whole
history.

The guide test proves the old payload still works:

```haskell
decodeRaw orderCodec 1 (object ["orderId" .= "order-100", "qty" .= 3])
```

The expected decoded event is:

```haskell
OrderPlaced (OrderId "order-100") (Sku "UNKNOWN") (Quantity 3)
```

Use this pattern for production event evolution:

- Keep event type names semantic and stable.
- Increment `schemaVersion` when the payload shape changes.
- Add consecutive upcasters from every supported old version.
- Test old payloads directly with `decodeRaw` and recorded-event tests with
  `decodeRecorded`.
- Prefer defaulting new fields over rewriting old event meaning.

The codec test lives in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs) under
`Jitsurei codec evolution`.
