# Codec and Event Schema Strategy — keiro

Author: ExecPlan EP-2 (`docs/plans/2-codec-and-event-schema-strategy.md`). Date: 2026-05-05.

This document fixes the codec layer that sits between keiro's typed domain events (`co` from `SymTransducer phi rs s ci co`) and kiroku's storage (`Aeson.Value` payloads tagged by a free-form `event_type :: Text`). It is consumed by EP-1's `runCommand`, EP-3's subscription handlers, and EP-4's snapshot serialization. The accompanying spike at `spikes/codec/` is the empirical proof that the chosen shape supports schema evolution under real `kiroku-store` reads/writes.

The reader is assumed to have read `docs/research/06-command-cycle-design.md` (EP-1's design) and either skimmed or read `spikes/codec/notes/hindsight-evaluation.md` (the prior-art evaluation). Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this design.


## 1. Problem statement

Kiroku stores event payloads as `Aeson.Value` (untyped JSONB) and tags them by a free-form `EventData.eventType :: Text` discriminator (see `docs/research/01-kiroku-read-side.md` §"Append API" / §"Read APIs"). Keiki, on the other hand, works on typed domain events `co` — the output alphabet of `SymTransducer phi rs s ci co` (see `docs/research/02-keiki-decide-loop.md`). Without a deliberate codec layer between them every keiro user would invent their own ad-hoc encoder/decoder, get the type tag wrong on the first schema change, and discover incompatibilities only when an old event is replayed years later in production.

This document fixes how keiro handles the four interlocking concerns:

1. **Encoding** a current-version typed event to JSON for write.
2. **Decoding** a JSON event of *any* historical schema version back to the current typed shape.
3. **Type-tagging** events stably so kiroku-side filtering and routing keep working across schema changes.
4. **Schema evolution** via an explicit, ordered chain of upcasters from one version to the next.

The keiro user-visible behaviour: an aggregate author writes one `Codec` value per event sum, declares schema versions explicitly, and gets confidence that every wire-shape produced by previous deploys can still be decoded.


## 2. Codec interface

The keiro codec is a value-level record of functions:

    data Codec e = Codec
      { codecEncode    :: e -> Aeson.Value
      , codecDecode    :: Aeson.Value -> Either String e
      , codecTypeTag   :: e -> Text
      , codecVersion   :: Int
      , codecUpcasters :: [(Int, Aeson.Value -> Either String Aeson.Value)]
      }

The shape was chosen over a typeclass for the same reasons keiki itself prefers records-of-functions over typeclasses (see EP-2's Decision Log entry of 2026-05-04): a record is a first-class value, multiple codecs for the same Haskell type can coexist (the production codec and a fixture codec for tests, for instance), and the spike's verdict on hindsight (§11 below) explicitly rejects the type-class style.

Each field's responsibility:

- `codecEncode :: e -> Aeson.Value`. Encodes an event in *the current schema*. Never produces an old-shape JSON. Total — the function is expected to succeed for every constructor of the event sum.
- `codecDecode :: Aeson.Value -> Either String e`. Decodes a JSON value *that is already at* `codecVersion`. The `Either String e` allows reporting structural errors; a `Left` here is a programming error (the JSON was migrated through the upcaster chain and *still* doesn't match) and should not happen on a healthy event log.
- `codecTypeTag :: e -> Text`. Stable per-constructor wire tag. *Independent* of schema version. Written into kiroku's `event_type` column at append time and used by subscription handlers to route on event kind without decoding the JSON payload. A value-level function (rather than a `Map`/`Set`) keeps the tag definition co-located with the event constructors.
- `codecVersion :: Int`. The current schema version. Events written today carry this number in their `EventData.metadata.schemaVersion`. Must increase monotonically over time as the wire shape evolves.
- `codecUpcasters :: [(Int, Aeson.Value -> Either String Aeson.Value)]`. The schema-evolution chain. Each entry `(n, f)` describes the migration from version `n` to version `n + 1`. Entries must be ascending and contiguous; gaps are rejected at decode time.

The keiro `EventStream phi rs s ci co` record (defined in EP-1) carries one `Codec co` value per aggregate type. Process managers (EP-3) reuse the same codec for decoding `RecordedEvent.payload` into the typed event sum.

The accompanying decode helper:

    decodeRecorded :: Codec e -> RecordedEvent -> Either DecodeError e

reads the schema version off the recorded event's metadata, walks the upcaster chain to bring the payload up to `codecVersion`, and finally hands it to `codecDecode`. The error sum:

    data DecodeError
      = UnknownVersion       !Int
      | UpcasterError        !Int !String
      | DecodeFailed         !String
      | GapInUpcasterChain   !Int !Int
      deriving stock (Eq, Show)

`UnknownVersion` fires when the recorded version pre-dates anything the codec can handle. `UpcasterError` fires when a chain step rejects its input (a malformed record). `DecodeFailed` fires when the post-migration JSON still doesn't match the current shape (a programming error). `GapInUpcasterChain (skippedFrom, skippedTo)` fires when the chain skips a version — a misconfigured codec.

The spike's `spikes/codec/src/Spike/Codec.hs` implements every name in this section. EP-1's `runCommand` (after the production library lands) replaces the spike's bare `esEncode`/`esDecode` pair with `esEventCodec :: Codec co`; the encoder/decoder slots disappear and `runCommand` invokes `encodeForAppend` and `decodeRecorded` instead.


## 3. Type-tag convention

`codecTypeTag :: e -> Text` produces the value written into kiroku's `EventData.eventType` field. The conventions:

1. **Stable across schema versions.** The tag is the *kind* of event; the *shape* lives in the metadata's schema version. Renaming a tag breaks every projection subscribed by `event_type` for no benefit; never rename a tag — add a new constructor and an upcaster to bridge the old tag to the new one if the rename is unavoidable.
2. **PascalCase, domain term, single string.** Examples: `"OrderPlaced"`, `"PaymentAuthorized"`, `"AccountConfirmed"`. No prefix, no namespace. EventStream-disambiguation lives in the stream name (`order-1`'s category prefix `order` already separates aggregates from each other at the kiroku level).
3. **Registered exactly once per codec.** Two codecs producing the same tag for distinct payload shapes is a silent collision — projections will receive both kinds and their decoders will mostly fail. The spike does not enforce this at the type level (the `Text` shape allows it); the production library should add a runtime registry that asserts uniqueness at startup.
4. **Reuse across aggregates is forbidden.** If two aggregates both have an "OrderPlaced" event, namespace one of them (`PaymentOrderPlaced`, `WarehouseOrderPlaced`). Event types are flat per kiroku-store; reusing the tag forces every category subscription to do its own dispatch.

Migration aid: a stream with an old tag rename can be back-filled with new-tag events using kiroku's link facility (`linkToStream`), but that is an exceptional operation and out of scope for v1 keiro.


## 4. Schema-version convention

The schema version is recorded under `EventData.metadata.schemaVersion :: Int` — *not* mixed into the type tag. Rationale:

- A type tag mixed with version (`"OrderPlaced.v2"`) breaks every projection subscribed by tag the moment the version changes; subscribers would have to know the version to wire up the routing.
- The metadata field already exists in `kiroku-store` (`EventData.metadata :: Maybe Aeson.Value`), is JSONB-indexed, and is intended exactly for this kind of envelope data. No upstream change is needed (EP-6 records "no kiroku-side codec gap").
- The version lives next to the tag (in the same `RecordedEvent`), so a decoder can look up the codec by tag and the version by metadata in one row, no joins.

The metadata key is the literal string `"schemaVersion"`. Its value is a non-negative `Int` (encoded as a JSON `Number`). Records that pre-date the convention — older events written before the codec layer existed — are interpreted as version `1` when the field is missing or the metadata object itself is absent. The default is conservative: aggregates that adopted the codec mid-deploy should set `codecVersion = 2` from the start so v1 records (the legacy ones) are visibly upcastable.

A v1-only codec (no schema evolution yet) sets `codecVersion = 1` and `codecUpcasters = []`. The `decodeRecorded` helper notices `version >= codecVersion` and skips the chain entirely.

Other metadata fields are reserved for keiro's observability layer (see `docs/research/06-command-cycle-design.md` §12): `keiro.command.id`, `keiro.command.tag`, `keiro.event_stream.id`, `keiro.event_stream.type`, `keiro.attempt`, `keiro.span.trace_id`, `keiro.span.span_id`. The codec layer leaves these alone; the keiro production library sets them at `encodeForAppend` time.


## 5. Upcaster chain ordering

`codecUpcasters` is a list of `(Int, Aeson.Value -> Either String Aeson.Value)` pairs. Entry `(n, f)` migrates a payload of version `n` to a payload of version `n + 1`. Two invariants:

1. **Ascending.** Entries must be sorted by source version. The decode-time walk reads them in order; out-of-order entries would cause the walk to skip steps.
2. **Contiguous.** Every version from the lowest entry up to `codecVersion - 1` must have an upcaster. Missing entries (e.g. an event at versions 1, 2, 3, 4 with upcasters for 1→2 and 3→4 but no 2→3) are rejected with `GapInUpcasterChain (2, 3)` at decode time.

The walker is a straightforward fold:

    migrateToCurrent codec srcVer payload
      | srcVer >= codecVersion codec = Right payload
      | otherwise = walk srcVer payload
      where
        walk v acc | v >= codecVersion codec = Right acc
                   | otherwise = case lookup v (codecUpcasters codec) of
                       Just f  -> case f acc of
                         Right acc' -> walk (v + 1) acc'
                         Left err   -> Left (UpcasterError v err)
                       Nothing -> {- gap or unknown version -}

Why pure functions on `Aeson.Value` rather than typed-version data types? Three reasons:

- **Aeson.Value is the wire format**. The migration is a JSON-to-JSON transformation; modelling each version as a separate Haskell type would force one `FromJSON` / `ToJSON` instance per version per event, plus a per-step typed-conversion layer. The aggregate author's surface area would multiply by `n`.
- **Pure JSON migrations are easy to test**. The spike's `upcastV1ToV2` is one `Aeson.Parser` walk over an envelope object; the test is "feed it a v1 sample, assert the result equals a v2 sample".
- **Hindsight (the type-level alternative) is rejected for keiro** — see §11 below for the verdict.

The trade-off: a missing upcaster surfaces as a *runtime* `GapInUpcasterChain` rather than a compile-time error. The mitigation is the testing strategy (§10): every codec must have a property test that asserts `decode . encode == Right` for the *current* version, plus a fixture file per supported old version asserting the v1-shaped JSON decodes to the expected current-version value. This catches the same bugs hindsight catches at compile time, at the cost of a per-codec test commit.


## 6. Unknown-event policy

A `RecordedEvent` whose `eventType` does not appear in any registered codec is *unknown* to keiro. Three policies are conceivable:

- **Skip-and-warn.** Drop the event silently (log a warning). Risks letting unknown events accumulate in the stream until a downstream subscriber discovers months of missed audits.
- **Quarantine.** Move the event to a side-channel for manual review.
- **Fatal.** Refuse to proceed; require the operator to register a codec or upgrade the binary.

**Default: fatal.** Replays must decode every event. The prior-art survey at `docs/research/05-workflow-prior-art.md` records that silent-skip has caused production bugs in every system that ships it as a default. Override per aggregate when truly necessary, with a Decision-Log entry on the aggregate's documentation justifying the override (typical reason: a deprecated subscription that intentionally ignores certain event kinds).

Concretely, EP-1's `runCommand` raises `CommandError.DecodeError` on an unknown event type. EP-3's subscription handlers will surface the same error before invoking the user-supplied handler, so the handler never sees an unknown event.


## 7. Integration with `runCommand` (EP-1)

EP-1's `runCommand` (per `docs/research/06-command-cycle-design.md` §4) takes an `EventStream phi rs s ci co` record. The production shape carries `esEventCodec :: Codec co`. The cycle's two codec touch-points:

- **At append time.** `encodeForAppend (esEventCodec agg) ev` constructs the `EventData` written to kiroku. Sets `eventType = codecTypeTag (esEventCodec agg) ev`, `payload = codecEncode (esEventCodec agg) ev`, and `metadata.schemaVersion = codecVersion (esEventCodec agg)`.
- **At hydration time.** Inside the Streamly fold's `replayStep`, `decodeRecorded (esEventCodec agg) recordedEvent` produces the typed `co` consumed by `applyEvent`. Decode failures raise `CommandError.DecodeError`; replay failures (event matches no edge under the post-decode value) raise `CommandError.ReplayError`. The two errors are distinct so the operator can attribute root cause cleanly.

EP-1's spike (`spikes/command-cycle/src/Spike/EventStream.hs`) collapses the codec into a bare `esEncode`/`esDecode` pair because EP-2 (this plan) had not landed when the spike was written. The production keiro library replaces that pair with the `Codec co` field; the API change is mechanical and is documented in EP-1's M2 design doc as a forward reference to this plan.

EP-1's M1 spike also surfaced an aggregate-author invariant — event payloads must be direct projections of input fields, not computed terms — that the codec cannot help with. That invariant is owned by `keiki` itself (the `OutFields` shape on the edge's `OutTerm`) and is documented in EP-1 §5. The codec sees only the resulting JSON; whether the JSON encodes a recoverable inverse is keiki's concern.


## 8. Integration with snapshots (EP-4)

Snapshot serialization is *not* covered by this plan. EP-4 will define `StateCodec (s, RegFile rs)` — a separate codec for the joint state, not for events. The reasons to keep them separate:

- The shape is different: events are sum types with stable per-constructor tags; the joint state is a product of the control vertex and a heterogeneous register file. Encoding "the third register slot of a five-slot RegFile is a `UTCTime`" needs walking machinery the event codec doesn't.
- The lifecycle is different: events accumulate forever; snapshots are written periodically and rebuilt on schema change. Snapshot codecs may legitimately rebuild from scratch on a schema change rather than carry a chain of upcasters.
- Versioning semantics differ: events carry their own version per record; snapshots are versioned at the *aggregate* level (every snapshot for an aggregate uses the same shape).

The register-file half is non-trivial: `RegFile rs` is keiki's typed heterogeneous tuple of slots. EP-6 will request a keiki-side serialization helper that produces `RegFile rs <-> Aeson.Value` from the slot list's `ToJSON`/`FromJSON` instances. Without that helper every aggregate author hand-rolls the encoding; with it, snapshot codecs can be derived.

This plan's `Codec e` shape and the future `StateCodec (s, RegFile rs)` are not nominal subtypes of each other — they share inspiration but not signatures. EP-4's design doc cross-references this plan for the patterns; the helpers (upcaster chain, version-on-metadata) translate.


## 9. Generic-deriving option

The spike hand-writes the `Codec OrderEvent` value (`spikes/codec/src/Spike/Order.hs`) — explicit `ToJSON` / `FromJSON` instances on the per-version data types, an explicit `codecEncode` that wraps in a `{tag, contents}` envelope, and an explicit upcaster.

For ergonomics, the production library should expose a generic helper:

    codecFromGeneric
      :: ( Generic e, GToJSON' Value Zero (Rep e), GFromJSON Zero (Rep e) )
      => Text       -- type tag
      -> Int        -- current version
      -> [(Int, Value -> Either String Value)]  -- upcasters
      -> Codec e

This produces a `Codec e` for any event sum whose `Generic`-derived `ToJSON`/`FromJSON` instances match the desired wire shape. The recommended default is the explicit-tag envelope (`{tag, contents}`) — Aeson's `genericToJSON` with `defaultOptions { sumEncoding = TaggedObject "tag" "contents" }` produces this shape directly.

EventStream authors can opt out of the helper by writing a `Codec` literal by hand whenever the wire shape needs to deviate (e.g. CBOR instead of JSON, a flatter envelope for backwards compatibility, a discriminated union with multiple alternative tags). The explicit form remains the canonical interface.

EP-2 ships v1 with the generic helper as a *convenience*; v2 may add a TH-based variant once the patterns settle.


## 10. Testing strategy

Every codec must have:

1. **A roundtrip property test.** `decode . encode == Right`. Generate `e` values via `Arbitrary`; assert the round-trip is identity. The spike's `scenarioStressTest` does this for 10 000 events. The production library exposes a helper:

       codecRoundtripProperty :: (Arbitrary e, Eq e, Show e) => Codec e -> Property

2. **A golden test per supported old version.** A fixture file `tests/fixtures/<TypeTag>-v<n>.json` carries a hand-curated JSON sample at version `n`. The test asserts `decodeRaw codec n fixture` produces the expected current-version value. This catches schema-evolution regressions: editing `upcastV1ToV2` to do the wrong thing on a v1 sample fails the golden test before it reaches production.

3. **A version-vector exhaustiveness test.** Iterate over `1 .. codecVersion`, assert each version is reachable through the upcaster chain. This catches `GapInUpcasterChain` at test time, not at decode time. The chain walker in §5 already detects gaps; the test exercises it for every supported source version.

The three together substitute for the compile-time guarantees that the rejected hindsight machinery (§11) would have given. They are mandatory for any aggregate that ships a `Codec` value to production.

The spike does not implement (1)/(2)/(3) as separate test cases — it inlines a roundtrip assertion inside the scenario driver. The production library will export the helpers and a `Tasty.TestTree` composer that takes a `[Codec SomeEvent]` and produces the full battery automatically.


## 11. Prior art: hindsight

`/Users/shinzui/Keikaku/hub/haskell/hindsight` (BSD-3, ~3K lines) is a Haskell library for type-level schema evolution. Its core machinery:

- Event identity is a type-level `Symbol` (e.g. `"user_created"`).
- Each event carries a `MaxVersion event :: Nat` type family and a `Versions event :: [Type]` family listing the payload type per version.
- Schema migrations are `instance Upcast n event` declarations, one per consecutive transition. The compiler automatically composes them into a `MigrateVersion` chain via a default instance.
- A `parseMap` produces a `Map Int (Value -> Parser CurrentPayloadType)` covering every supported version.
- A test-generation toolkit (`Test.Hindsight.Generate`) walks the `Versions` family to derive roundtrip and golden tests for every declared version.

The full evaluation lives at `spikes/codec/notes/hindsight-evaluation.md`. The EP-2 verdict, recorded in this plan's Decision Log on 2026-05-05, is **selectively borrow**.

What keiro adopts from hindsight (translated to value level):

- **The consecutive-upcaster pattern.** The `[(Int, Value -> Either String Value)]` chain is the value-level translation of hindsight's `instance Upcast n event` series.
- **The version-vector concept.** `codecVersion` plus the chain length implicitly defines the version vector; every version from `1` to `codecVersion` must round-trip.
- **The test discipline.** §10's roundtrip + golden + exhaustiveness tests substitute for hindsight's auto-derived test toolkit.

What keiro rejects from hindsight:

- **Type-level event registry (`MaxVersion`, `Versions` families).** Keiro keeps the type tag at the value level (`codecTypeTag :: e -> Text`) so the registry coexists with kiroku's runtime `event_type` text indexing. Hindsight's type-level Symbol would force a Symbol-to-Text translation layer at every kiroku boundary, adding ~10 lines of glue per integration point.
- **Peano-numbered `Upcast n` instances and `MigrateVersion` automatic composition.** Keiro composes the chain at runtime via `migrateToCurrent`. The compile-time exhaustiveness this gives up is replaced by §10's runtime test battery.
- **`SomeLatestEvent` existential wrapper.** Keiki's `SymTransducer co` already supplies a domain sum of event constructors — the exact shape keiro needs. Wrapping each constructor into hindsight's `SomeLatestEvent` adds 20-30 lines of conversion glue per aggregate.
- **Hindsight's `EventStore` and subscription abstractions.** Kiroku-store is keiro's storage; shibuya is keiro's subscription engine. Both already expose the contract keiro needs.

The trade-off, stated frankly: hindsight catches schema-evolution bugs at compile time that keiro will catch at runtime (or at test time if §10 is followed). The boilerplate cost of hindsight (~20+ lines per event including type-instance declarations and `SomeLatestEvent` glue) is higher than the value-level alternative (~6 lines per event for a `Codec e` value plus the per-version `Aeson` instances). For a codebase the size of keiro's eventual user base, the boilerplate cost loses; the test discipline catches the same bugs.

If a future keiro user explicitly wants hindsight-grade compile-time guarantees, they can ship their own `HindsightCodec e` adapter that constructs a `Codec e` from hindsight's machinery without modifying keiro's core. The interface is small enough to permit that as a downstream library.


## 12. Open questions and upstream gaps

Forwarded to EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`) for the consolidated kiroku/keiki feature backlog.

**kiroku-side.**

- *No changes required for the codec layer itself.* `EventData.metadata`, `EventData.eventType`, and `EventData.payload` already exist with the right shapes. The codec rides entirely on existing kiroku primitives.
- *(Reiterated from EP-1 §14 for completeness)* Postgres 18 is required because kiroku's schema uses `uuidv7()`. The codec layer does not introduce new SQL; the version constraint is inherited.

**keiki-side.**

- *Register-file serialization helper.* EP-4's snapshot codec needs `RegFile rs <-> Aeson.Value`. Without a keiki-side helper that walks the slot list and uses each slot type's `ToJSON`/`FromJSON` instances, every aggregate author hand-rolls the encoding. EP-2 cannot land this helper itself (it touches keiki's pure core); the request lives in EP-6. **[CLOSED 2026-05-14 — shipped as the new sibling package `keiki-codec-json` (v0.1.0.0): `Keiki.Codec.JSON.regFileToJSON :: RegFile rs -> Aeson.Value`, `regFileFromJSON :: Aeson.Value -> Either String (RegFile rs)`, `regFileToEncoding :: RegFile rs -> Aeson.Encoding` (streaming variant), plus TH derivation `deriveRegFileCodec` / `deriveRegFileCodecAs`. The companion shape hash (`Keiki.Shape.regFileShapeHash` in core keiki) covers the snapshot-discriminant half of EP-4's needs. Living in a sibling package keeps `keiki/CHANGELOG.md`'s "no built-in serialization in core" invariant intact while making the helper available to keiro. Keiro-side integration tracked by EP-9 (`docs/plans/9-integrate-keiki-codec-json-into-keiro-snapshot-path.md`), queued waiting on EP-37 Hackage upload. See `docs/research/11-upstream-roadmap.md` 2026-05-14 corrections note.]**
- *(Reiterated from EP-1 §14)* Compile-time check that event payloads are inverse-recoverable — the keiki invariant that `solveOutput` only inverts direct field projections. The codec sees only the resulting JSON; whether keiki can replay it is keiki's invariant. The request lives in EP-6 as a keiki-side gap. **[Status 2026-05-14: still open. See `docs/research/11-upstream-roadmap.md` §7.4.]**

**keiro-side (within this plan's scope).**

- *Generic codec helper.* §9's `codecFromGeneric` should ship in v1 alongside the explicit `Codec e` literal form. The implementation depends on Aeson's `genericToJSON`/`genericParseJSON` plus an envelope wrapper; the production library will land it once the `EventStream phi rs s ci co` record's exact shape is finalised in EP-1's `Keiro.EventStream` module.
- *Tasty test-tree composer.* §10's `codecRoundtripProperty` plus a golden-test composer should ship as a `Keiro.Codec.Test` module. Out of scope for the M1 spike; production library work item.
- *Type-tag registry.* §3 says reuse across aggregates is forbidden but does not yet enforce it. The production library should expose a `KeiroRegistry` value that asserts uniqueness at startup. Out of scope for the M1 spike; production library work item.


## 13. How to verify

The spike at `spikes/codec/` is the empirical proof. Run it the same way as the EP-1 spike:

    cd /Users/shinzui/Keikaku/bokuno/keiro/spikes/codec
    nix develop /Users/shinzui/Keikaku/bokuno/keiki --command bash -c \
      'export PATH=/nix/store/nh8iirirvq79f54pgz71ylqmmwi1gpc9-postgresql-18.3/bin:$PATH; \
       cabal build all && cabal run spike'

Expected last line: `[codec-spike] OK`. Every public type or function named in this document is realized in the spike's `Spike.Codec` and `Spike.Order` modules. A reviewer who reads this document and the spike's source should be able to answer "how does keiro handle a 5-year-old event whose payload shape no longer matches?" by walking through `decodeRecorded` once.


## 14. Summary

keiro's codec layer is a value-level `Codec e` record carrying encode + decode + type-tag + version + an explicit chain of consecutive upcasters. Schema versions are recorded in `EventData.metadata.schemaVersion`; type tags stay stable across versions so projections subscribed by `event_type` keep working. Schema evolution happens at decode time via the upcaster chain; old wire shapes are migrated to the latest before `codecDecode` runs. Unknown event types are fatal by default. The `hindsight` library was evaluated as prior art (`spikes/codec/notes/hindsight-evaluation.md`) and the verdict is selectively borrow — keiro adopts the consecutive-upcaster pattern, the version-vector concept, and the test discipline at the value level, but rejects hindsight's type-level machinery to keep the codec compatible with kiroku's runtime `event_type` registry and keiki's domain-sum `co`.

EP-1 (command cycle) consumes `Codec co` via the `EventStream.esEventCodec` field; the production library replaces the spike's bare encode/decode pair with the `Codec` value. EP-3 (subscriptions, projections, process managers) reuses the same codec for decoding `RecordedEvent.payload` into the typed event sum. EP-4 (snapshots) defines a separate `StateCodec (s, RegFile rs)` informed by this plan's patterns but with its own version semantics. EP-6 (upstream roadmap) consolidates the keiki-side `RegFile` serialization helper as the only upstream gap this plan introduces.
