# Codecs And Event Evolution

Keiro stores events as Kiroku `EventData`: an event type tag, JSON payload,
metadata, and optional ids. `Keiro.Codec` is the boundary between stored events
and domain events.

## Codec Shape

```haskell
data Codec e = Codec
  { eventTypes :: NonEmpty EventType
  , eventType :: e -> EventType
  , schemaVersion :: Int
  , encode :: e -> Value
  , decode :: EventType -> Value -> Either Text e
  , upcasters :: [Upcaster]
  }

type Upcaster = (Int, EventType -> Value -> Either Text Value)
```

`eventTypes` is required because hydration must reject unknown stored event type
tags before attempting payload decoding. The stored `EventType` is authoritative:
`decode` receives it after migration, and each upcaster receives it while
migrating. This lets one codec own several event kinds without guessing the kind
from payload fields.

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
4. runs the current `decode` with the stored event type tag.

Unknown event types and decode failures stop hydration. This is deliberate:
continuing from a partial history would make command decisions unsafe.

DSL-generated codecs merge all event migrations for one schema rung into one
dispatcher. The dispatcher selects the event-specific upcaster by `EventType`
and passes every other event kind through unchanged. This keeps each generated
upcaster hole focused on one payload while making the multi-event behavior
automatic.

## Upcaster Chains

An upcaster `(n, f)` migrates payloads from version `n` to version `n + 1`.

For a current `schemaVersion` of 4, a version 1 event needs upcasters for
versions 1, 2, and 3.

```haskell
orderCodec = Codec
  { schemaVersion = 3
  , upcasters =
      [ (1, dispatchUpcastV1ToV2)
      , (2, dispatchUpcastV2ToV3)
      ]
  , ...
  }
```

If Keiro finds a later upcaster but the immediate next step is missing, it
returns `GapInUpcasterChain`. If no later rung exists but the codec has not
reached its current version, it returns `IncompleteUpcasterChain`.

Upcasters are permanent compatibility code. Every schema version ever written
must retain a contiguous chain to the current version. Keiro has no mechanism
for declaring an old stored version unsupported.

See [Evolve Events Safely](../guides/evolve-events-safely.md) for the
`jitsurei` order codec and a tested version-1-to-version-2 `OrderPlaced`
upcaster.

## Versioning Rules

Use these rules for event evolution:

- Never change the meaning of an existing event type tag in place.
- Increment `schemaVersion` when the payload shape changes.
- Keep upcasters consecutive from every version ever written.
- Treat schema versions as aggregate-wide. When another event kind changes,
  advance from the aggregate's current maximum version rather than restarting
  that event's private sequence.
- Add tests for each old payload version.
- Prefer additive fields with defaults over destructive reshapes.
- Keep event names semantic, not implementation-specific.

Aggregate codec bumps cannot use an ordinary mixed-version rolling deployment:
an old binary rejects a newly written version with `VersionAhead`. The
deployment cutover procedure is documented in this initiative's deploy-ordering
reference.

## Validating Codec Configuration

Prefer `mkCodec` when constructing a codec by hand. It rejects:

- schema versions below 1;
- duplicate event type tags;
- duplicate upcaster source versions;
- upcaster source versions outside `1 .. schemaVersion - 1`;
- missing rungs in the chain to the current schema version.

The raw `Codec` constructor remains exported as a low-level escape hatch.
Regardless of how a codec was built, `validateEventStreamWith` runs `mkCodec`
when constructing a `ValidatedEventStream`, so `mkEventStream`,
`mkEventStreamWith`, and `mkEventStreamOrThrow` all fail before the stream can
serve commands when its codec is invalid. Only the explicitly unsafe
`mkEventStreamUnchecked` bypasses that boundary.

The durable layering of DSL checks, diffs, stream construction, and golden
payload tests is recorded in
[ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md).

## Codec Errors

`CodecError` values:

- `UnknownEventType EventType [EventType]` — the selected tag is outside the
  codec's allow-list; encoding and decoding can both return it.
- `InvalidSchemaVersion Int` — the codec version is below 1; encoding can
  return it when raw construction bypassed `mkCodec`.
- `UnknownVersion Int` — a stored payload declares a version below 1.
- `VersionAhead Int Int` — a stored payload was written by a newer codec.
- `UpcasterError Int Text` — the upcaster for the reported source version
  rejected its payload.
- `DecodeFailed Text` — the current decoder rejected the migrated payload.
- `GapInUpcasterChain Int Int` — migration found a later rung while the
  immediately required rung was absent.
- `IncompleteUpcasterChain Int Int` — the available chain ended before the
  codec's current version.
- `MalformedSchemaVersionStamp Value` — present event metadata contained an
  invalid schema-version value.
- `NonObjectCallerMetadata Value` — caller-supplied append metadata was not a
  JSON object; only encoding can return it.

During command handling, stored-event failures appear as
`HydrationDecodeFailed CodecError`; failures while encoding newly emitted
events appear as `EncodeFailed CodecError`.

## Testing Codecs

For each codec, test:

- current event round trip;
- stored event type tag;
- schema-version metadata;
- every supported old version upcasts to the expected current event;
- unknown type tags are rejected;
- malformed payloads fail with useful messages.

Keep a versioned JSON golden for every old wire shape and exercise it through
`decodeRaw codec eventType version payload`. `keiro-dsl diff --emit-goldens`
captures old shapes while both specifications exist, and generated conformance
harnesses embed the goldens supplied to `scaffold --goldens`.

The repository test suite has examples in the `Keiro.Codec` group. See
[Evolve Events Safely](../guides/evolve-events-safely.md) for a worked example
and [Evolution And Replayability](../guides/evolution-and-replayability.md) for
the procedure for each change class.
