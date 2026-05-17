# Codecs And Event Evolution

Keiro stores events as Kiroku `EventData`: an event type tag, JSON payload,
metadata, and optional ids. `Keiro.Codec` is the boundary between stored events
and domain events.

## Codec Shape

```haskell
data Codec e = Codec
  { eventTypes :: NonEmpty Text
  , eventType :: e -> Text
  , schemaVersion :: Int
  , encode :: e -> Value
  , decode :: Value -> Either Text e
  , upcasters :: [Upcaster]
  }

type Upcaster = (Int, Value -> Either Text Value)
```

`eventTypes` is required because hydration must reject unknown stored event type
tags before attempting payload decoding.

## Encoding

`encodeForAppend` validates:

- `schemaVersion > 0`;
- selected `eventType` is present in `eventTypes`.

It returns Kiroku `EventData` with:

- `eventType` set from your domain event;
- `payload` set from `encode`;
- metadata containing `schemaVersion`;
- no event id unless later supplied through `RunCommandOptions.eventIds`.

Use `encodeForAppendWithMetadata` when you need to merge additional JSON object
metadata with the schema version.

## Decoding

`decodeRecorded`:

1. checks that the stored event type tag is known;
2. extracts `schemaVersion` from metadata, defaulting to version 1 when absent;
3. runs upcasters when the stored version is older than the current version;
4. runs the current `decode`.

Unknown event types and decode failures stop hydration. This is deliberate:
continuing from a partial history would make command decisions unsafe.

## Upcaster Chains

An upcaster `(n, f)` migrates payloads from version `n` to version `n + 1`.

For a current `schemaVersion` of 4, a version 1 event needs upcasters for
versions 1, 2, and 3.

```haskell
orderCodec = Codec
  { schemaVersion = 3
  , upcasters =
      [ (1, upcastOrderV1ToV2)
      , (2, upcastOrderV2ToV3)
      ]
  , ...
  }
```

If Keiro finds a later upcaster but the immediate next step is missing, it
returns `GapInUpcasterChain`.

See [Evolve Events Safely](../guides/evolve-events-safely.md) for the
`jitsurei` order codec and a tested version-1-to-version-2 `OrderPlaced`
upcaster.

## Versioning Rules

Use these rules for event evolution:

- Never change the meaning of an existing event type tag in place.
- Increment `schemaVersion` when the payload shape changes.
- Keep upcasters consecutive from every stored version you still support.
- Add tests for each old payload version.
- Prefer additive fields with defaults over destructive reshapes.
- Keep event names semantic, not implementation-specific.

## Codec Errors

`CodecError` values:

- `UnknownEventType EventType [Text]`
- `InvalidSchemaVersion Int`
- `UnknownVersion Int`
- `UpcasterError Int Text`
- `DecodeFailed Text`
- `GapInUpcasterChain Int Int`

In command handling, these appear as `HydrationDecodeFailed` or `EncodeFailed`.

## Testing Codecs

For each codec, test:

- current event round trip;
- stored event type tag;
- schema-version metadata;
- every supported old version upcasts to the expected current event;
- unknown type tags are rejected;
- malformed payloads fail with useful messages.

The repository test suite has examples in the `Keiro.Codec` group.
