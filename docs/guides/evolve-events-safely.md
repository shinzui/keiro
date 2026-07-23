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
  { eventTypes =
      EventType "OrderPlaced"
        :| [ EventType "PaymentApproved"
           , EventType "OrderPacked"
           , EventType "OrderShipped"
           , EventType "OrderCancelled"
           ]
  , schemaVersion = 2
  , encode = ...
  , decode = parseOrderEvent
  , upcasters = [(1, const upcastOrderPlacedV1)]
  }
```

The current `OrderPlaced` payload uses `quantity`. Version 1 used `qty`. The
upcaster reads the old field, supplies a default SKU when the old payload does
not have one, and returns the current version-2 JSON shape:

```haskell
upcastOrderPlacedV1 :: Value -> Either Text Value
```

The codec-level `Upcaster` receives the stored event type as well as the JSON
payload. This single-event helper stays payload-only because `orderCodec`
stores it as `(1, const upcastOrderPlacedV1)`. For a generated multi-event
codec, the generated rung dispatches by `EventType` before calling the
payload-only helper and passes unrelated event kinds through unchanged.

During hydration, `runCommand` calls `decodeRecorded`. That function checks the
stored event type tag first, reads `schemaVersion` from metadata, runs each
needed upcaster in order, and only then decodes the current payload. Keiro does
not skip bad stored events because command decisions must be based on the whole
history.

The guide test proves the old payload still works:

```haskell
decodeRaw orderCodec (EventType "OrderPlaced") 1
  (object ["orderId" .= ("order-100" :: Text), "qty" .= (3 :: Int)])
```

The expected decoded event is a current record-payload event:

```haskell
OrderPlaced
  OrderPlacedData
    { orderId = OrderId "order-100"
    , sku = Sku "UNKNOWN"
    , quantity = Quantity 3
    }
```

Use this pattern for production event evolution:

- Keep event type names semantic and stable.
- Increment `schemaVersion` when the payload shape changes.
- Keep consecutive upcasters from every historical version; they are permanent
  compatibility code.
- Test old payloads directly with `decodeRaw` and recorded-event tests with
  `decodeRecorded`.
- Check in a versioned golden containing the genuine old payload shape.
- Prefer defaulting new fields over rewriting old event meaning.

The codec test lives in
[`../../jitsurei/test/Main.hs`](../../jitsurei/test/Main.hs) under
`Jitsurei codec evolution`.

For the full operational procedure, including deployment ordering and replay
checks, see
[Evolution And Replayability](evolution-and-replayability.md).
