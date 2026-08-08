---
title: "Typed event streams, codecs, and schema evolution"
type: Capability
description: "Declare typed stream names, versioned event codecs, event-type validation, and upcasters so a consumer's domain events have a stable on-disk contract."
generated:
  by: claude-code/sonnet-4.5
  at: "2026-08-08T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - keiro-core
interface:
  - Keiro.Stream
  - Keiro.Codec
  - Keiro.Codec.Structural
  - Keiro.Codec.Nominal
  - Keiro.Codec.IdDomain
  - Keiro.EventStream
  - Keiro.Integration.Event
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Stream', 'Keiro.Codec', 'Keiro.Codec.Structural', 'Keiro.Codec.Nominal', 'Keiro.EventStream', and 'Keiro.Integration.Event' describe blocks exercise typed stream names, structural and nominal codec round-trips, schema-versioned decode, and event-type validation."
  - kind: guide
    resource: docs/user/codecs-and-event-evolution.md
    proves: "How a consumer defines codecs, adds schema versions, and writes upcasters to evolve event payloads without breaking replay."
  - kind: example
    resource: jitsurei/src/Jitsurei/OrderStream.hs
    proves: "A runnable domain stream declaring its typed event set and codec as a real service would."
---

# Typed event streams, codecs, and schema evolution

This is the contract layer every other keiro capability builds on. A consumer
declares a typed stream name, an event codec, a schema version per event type,
and — when payloads change shape — an upcaster that rewrites older stored
payloads into the current type during replay. Event-type validation rejects a
stream whose declared event set does not match what the codec can encode and
decode.

Two codec strategies ship: a *structural* codec derived generically from the
Haskell type, and a *nominal* codec that pins wire representation to explicit
constructor and field names so a refactor of the Haskell type cannot silently
change the wire format. `Keiro.Codec.IdDomain` adds the frozen TypeID-v7
identifier contract for prefix-bearing ids (available since `keiro-core`
0.7.0.0; see the package changelog).

## Shape

```haskell
import Keiro.Stream
import Keiro.Codec

data OrderEvent = OrderPlaced … | OrderShipped …

orderCodec :: Codec OrderEvent
orderCodec = structuralCodec  -- or a nominal codec pinned to wire names
```

## Limits

- Upcasting is forward-only: a codec migrates older payloads up to the current
  type, and there is no supported path to decode a future payload with an older
  binary. Pin the schema version deliberately.
- The structural codec ties the wire format to the generic structure of the
  Haskell type; renaming a constructor or field changes the wire format. Use the
  nominal codec where wire stability across refactors matters — this is a real
  choice the consumer must make, not a default that is safe either way.
- Evidence for the codec and stream contracts is the monolithic
  `keiro/test/Main.hs` suite; there is no separate conformance corpus for the
  hand-written codec surface (unlike the `.keiro` toolchain — see
  CAP-14).
