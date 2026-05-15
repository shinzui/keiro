---
id: 11
slug: define-the-eventstream-contract-and-codec-surface
title: "Define the EventStream contract and codec surface"
kind: exec-plan
created_at: 2026-05-15T15:00:13Z
intention: "intention_01krp2azwjessavsfva1he2gx1"
master_plan: "docs/masterplans/2-keiro-library-bootstrap-and-v1-implementation-start.md"
---

# Define the EventStream contract and codec surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan gives keiro authors the public types they need to describe an event-sourced stream before any database command runner exists. After completion, a developer can define a typed `Stream a`, a `Codec e` for their domain event sum, and an `EventStream phi rs s ci co` value wrapping a keiki `SymTransducer`; pure tests can encode/decode events and construct the contract that EP-12 will execute.

The behavior is observable through compilation and unit tests: fixture event types round-trip through `Codec`, schema-version upcasters run in order, and the `EventStream` record can be constructed without importing internal modules.


## Progress

- [ ] M1 — Add `Keiro.Stream` with the typed `Stream a` wrapper and conversion to/from `Kiroku.Store.Types.StreamName`, following the jitsurei record patterns.
- [ ] M2 — Add `Keiro.Codec` with `Codec e`, encode/decode errors, type tags, schema versions, upcaster ordering, helper constructors, strict fields, and unprefixed field names.
- [ ] M3 — Add `Keiro.EventStream` with the `EventStream phi rs s ci co` record, `StateCodec`, and `SnapshotPolicy` placeholders using strict unprefixed fields.
- [ ] M4 — Add public re-exports in `Keiro` and pure tests for stream conversion, codec round trips, upcaster ordering, and EventStream construction.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep codec and EventStream authoring in one plan.
  Rationale: `EventStream` carries `Codec co`, so splitting these would force two plans to coordinate the same public record before any runtime behavior exists.
  Date: 2026-05-15.

- Decision: Name the typed event-stream identifier `Stream a`, accepting collision with `Streamly.Data.Stream.Stream`.
  Rationale: The research foundation recorded team feedback that `StreamRef` reads awkwardly and `Stream a` is the right public primitive. Haskell modules that need both names should import Streamly qualified. The newtype field should follow the local record-pattern guide: use a strict unprefixed field such as `name :: !StreamName`, and rely on `DuplicateRecordFields` plus `#name` where field access is needed.
  Date: 2026-05-15.

- Decision: All records introduced by this plan must follow `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`.
  Rationale: The implementation should be consistent with the rest of the user's Haskell code: no field prefixes, strict fields, explicit deriving strategies, and generic-lens `#label` access/update. The initial draft used prefixed field names, which would steer implementation away from the local convention.
  Date: 2026-05-15.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan depends on EP-10, `docs/plans/10-bootstrap-the-keiro-haskell-package.md`, because the source tree and Cabal package must exist first. It consumes the research designs in `docs/research/06-command-cycle-design.md` and `docs/research/07-codec-strategy.md`.

Keiro's event-stream contract is the bridge between kiroku and keiki. Kiroku stores events as `Kiroku.Store.Types.EventData` and reads them back as `RecordedEvent`, where the payload is `Data.Aeson.Value`, the type discriminator is `EventType Text`, stream positions are `StreamVersion`, and global positions are `GlobalPosition`. Keiki's pure core is `Keiki.Core.SymTransducer phi rs s ci co`, with `rs` the typed register file, `s` the state, `ci` the command/input type, and `co` the output event type. Keiro must not use the older `Keiki.Decider` facade as its core contract because the research foundation chose `SymTransducer` to preserve typed registers and epsilon edges.

The codec design from `docs/research/07-codec-strategy.md` is value-level. A `Codec e` turns a typed event into a stable event type tag, a schema version, and a JSON payload, and decodes a `RecordedEvent` back into `e` after applying consecutive upcasters. Schema versions live in event metadata, not in the type tag. Unknown event types are errors for command hydration and subscription handlers.


## Plan of Work

Milestone 1 creates `src/Keiro/Stream.hs`. Import `Keiro.Prelude` rather than repeating common imports. Define the newtype with a strict unprefixed field and explicit deriving strategies, for example:

```haskell
newtype Stream a = Stream
  { name :: !StreamName
  }
  deriving stock (Generic, Eq, Ord, Show)
```

Provide a safe `stream :: Text -> Stream a`, `streamName :: Stream a -> StreamName`, and `mapStreamName` only if needed by tests. Implement field access through `streamValue ^. #name` in code that needs the wrapped `StreamName`; do not introduce prefixed accessors. Avoid smart-constructor validation unless kiroku enforces the same validation; kiroku accepts most names and only reserves `$all` for mutation APIs.

Milestone 2 creates `src/Keiro/Codec.hs`. Import `Keiro.Prelude`. Define `Codec e` as a strict record containing event type selection, current schema version, encoding, decoding, and an upcaster chain. Field names must be ordinary nouns or verbs such as `eventType`, `schemaVersion`, `encode`, `decode`, and `upcasters`, not `codecEventType` or similar. Include functions equivalent to `encodeForAppend :: Codec e -> e -> Either CodecError EventData` and `decodeRecorded :: Codec e -> RecordedEvent -> Either CodecError e`. Encode the schema version in `EventData.metadata` using the convention from `docs/research/07-codec-strategy.md`; preserve existing metadata if the helper accepts metadata from callers. Upcasters must be consecutive; tests should fail a gap such as version 1 to version 3 with no version 2.

Milestone 3 creates `src/Keiro/EventStream.hs` and small snapshot placeholder modules if useful. Define:

```haskell
data EventStream phi rs s ci co = EventStream
  { transducer :: !(SymTransducer phi rs s ci co)
  , initialState :: !s
  , initialRegisters :: !(RegFile rs)
  , eventCodec :: !(Codec co)
  , streamName :: !(Stream (EventStream phi rs s ci co) -> StreamName)
  , snapshotPolicy :: !(SnapshotPolicy (s, RegFile rs))
  , stateCodec :: !(Maybe (StateCodec (s, RegFile rs)))
  }
  deriving stock (Generic)
```

Adjust types if the compiler or current keiki API requires it, but preserve the meaning and the record pattern. Do not add `es` prefixes. `SnapshotPolicy` and `StateCodec` can be records/types with no database implementation yet; EP-13 fills in behavior.

Milestone 4 updates `src/Keiro.hs` to re-export the author-facing modules and adds tests. Tests should construct a small event type with two schema versions, prove old JSON upcasts to the current event, prove unknown event type fails, and construct an `EventStream` using a tiny keiki transducer fixture.


## Concrete Steps

From `/Users/shinzui/Keikaku/bokuno/keiro`, confirm dependency APIs:

```bash
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiki --full
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Types.hs
sed -n '1,220p' /Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs
```

After editing, run:

```bash
cabal build all
cabal test all
```

Expected success includes the new pure test suite passing:

```text
Test suite keiro-test: PASS
```


## Validation and Acceptance

Acceptance requires public modules `Keiro.Stream`, `Keiro.Codec`, and `Keiro.EventStream` to compile and be re-exported from `Keiro`. Tests must verify stream-name conversion, event encode/decode, upcaster ordering, unknown event rejection, and construction of a representative `EventStream`. The implementation must import `Keiro.Prelude`, must use strict record fields, and must access records with `#field` lenses in nontrivial code.

No function in this plan should connect to PostgreSQL or call kiroku append/read APIs. Runtime behavior begins in EP-12.


## Idempotence and Recovery

All edits are additive under `src/` and `test/`. If the exact `EventStream` record from the research document fails to compile because keiki's `SymTransducer` type has evolved, inspect `/Users/shinzui/Keikaku/bokuno/keiki/src/Keiki/Core.hs`, update the field type to the current source, and record the drift in Surprises & Discoveries. Keep any rename local and cascade it to the MasterPlan Integration Points before later plans implement against it.


## Interfaces and Dependencies

This plan must leave these interfaces available to EP-12:

```haskell
module Keiro.Stream
  ( Stream(..)
  , stream
  , streamName
  )

module Keiro.Codec
  ( Codec(..)
  , CodecError(..)
  , encodeForAppend
  , decodeRecorded
  )

module Keiro.EventStream
  ( EventStream(..)
  , SnapshotPolicy(..)
  , StateCodec(..)
  )
```

The key dependencies are `Kiroku.Store.Types` for `StreamName`, `EventData`, `RecordedEvent`, `EventType`, `StreamVersion`, and `GlobalPosition`; `Keiki.Core` for `SymTransducer` and `RegFile`; `Data.Aeson` for JSON payloads and metadata; `Data.Text` for stable type tags; and `generic-lens`/`lens` for the local record access pattern.
