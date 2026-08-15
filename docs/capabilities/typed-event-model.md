---
title: "Typed event streams, codecs, and schema evolution"
type: Capability
description: "Declare typed stream names, codec-wide payload versions, event-type validation, upcasters, and generated-codec bindings so a consumer's domain events have an explicit on-disk contract."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
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
  - Keiro.Codec.Structural.Generic
  - Keiro.Codec.Nominal
  - Keiro.Codec.IdDomain
  - Keiro.EventStream
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'Keiro.Stream', 'Keiro.Codec', 'Keiro.Codec.Structural', 'Keiro.Codec.Nominal', and 'Keiro.EventStream' blocks exercise typed stream names, binding round-trips, codec construction, schema-versioned decode, and event-type validation."
  - kind: guide
    resource: docs/user/codecs-and-event-evolution.md
    proves: "How a consumer defines codecs, adds schema versions, and writes upcasters to evolve event payloads without breaking replay."
  - kind: example
    resource: jitsurei/src/Jitsurei/OrderStream.hs
    proves: "A runnable domain stream declaring its typed event set and codec as a real service would."
---

# Typed event streams, codecs, and schema evolution

This is the contract layer every other keiro capability builds on. A consumer
declares a typed stream name, an event codec with one current payload version,
and — when payloads change shape — a complete chain of upcasters that rewrites
older stored payloads into the current form during replay. An upcaster receives
the authoritative event-type tag, so one codec-wide version chain can migrate
different event variants correctly. Construction and event-stream validation
reject invalid schema versions, incomplete upcaster chains, duplicate or
undeclared event types, and a declaration whose event set does not match the
codec.

`Keiro.Codec.Structural` and `Keiro.Codec.Nominal` are stable binding contracts
between consumer-owned domain types and Keiro-owned wire shapes. They do not
derive or replace a codec: generated code remains the JSON authority, while the
bindings provide total conversions and conformance laws. The optional generic
helper derives only an exact structural binding. `Keiro.Codec.IdDomain` adds the
frozen TypeID-v7 identifier contract for prefix-bearing ids (available since
`keiro-core` 0.7.0.0; see the package changelog).

## Shape

```haskell
import Keiro.Stream
import Keiro.Codec

data OrderEvent = OrderPlaced … | OrderShipped …

orderCodec :: Either CodecConfigError (Codec OrderEvent)
orderCodec = mkCodec Codec
  { eventTypes = EventType "OrderPlaced" :| [EventType "OrderShipped"]
  , eventType = orderEventType
  , schemaVersion = 2
  , encode = encodeCurrentOrderEvent
  , decode = decodeCurrentOrderEvent
  , upcasters = [(1, upcastOrderEventV1)]
  }
```

## Limits

- Upcasting is forward-only: a codec migrates older payloads up to the current
  type, and there is no supported path to decode a future payload with an older
  binary. Pin the schema version deliberately.
- A codec has one current schema version, not an independent version per event
  type. A payload change in any owned event advances that codec-wide target and
  requires every migration rung; the event-type argument lets each rung branch.
- Structural and nominal bindings require total conversions. A constructor that
  can reject, normalize, or identify its representation is refined/opaque and
  must use the corresponding mapped toolchain surface instead.
- Evidence for the codec and stream contracts is the monolithic
  `keiro/test/Main.hs` suite; there is no separate conformance corpus for the
  hand-written codec surface (unlike the `.keiro` toolchain — see
  CAP-14).
