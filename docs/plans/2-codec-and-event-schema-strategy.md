---
id: 2
slug: codec-and-event-schema-strategy
title: "Codec and Event Schema Strategy"
kind: exec-plan
created_at: 2026-05-04T20:12:07Z
intention: "intention_01kqt8d9t8ehb84kgs19qa1rs9"
master_plan: "docs/masterplans/1-keiro-research-foundation.md"
---

# Codec and Event Schema Strategy

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kiroku stores event payloads as untyped JSON (`Aeson.Value` in `Kiroku.Store.Types.EventData.payload` and `Kiroku.Store.Types.RecordedEvent.payload`). Keiki, on the other hand, works on typed domain events (`co` in its native `SymTransducer phi rs s ci co`). Without a deliberate codec layer between them, every keiro user would have to invent their own ad-hoc encoder/decoder, get the type tag wrong on the first schema change, and discover incompatibilities only when an old event is replayed years later in production.

This plan resolves how keiro handles event encoding, decoding, type-tagging, and schema evolution. After it is complete, anyone with the keiro source tree can:

1. read a small design document at `docs/research/07-codec-strategy.md` that fixes the codec interface, the schema-versioning convention, and the upcaster pattern;
2. run a working spike at `spikes/codec/` that round-trips a sample aggregate's events through the codec — including a synthetic schema migration where v1-shaped JSON is upcast to v2 on read;
3. cite the design verbatim in EP-3 (subscriptions/projections) and EP-4 (snapshots), both of which need the same codec for `RecordedEvent.payload` decoding and for snapshot serialization.

The user-visible behaviour the eventual library will deliver: an aggregate author writes one `Codec` value per event sum, declares schema versions explicitly, and gets confidence that every wire-shape produced by previous deploys can still be decoded.


## Progress

- [x] M0.1 — 2026-05-05: Hindsight evaluation written to `spikes/codec/notes/hindsight-evaluation.md`. Covers the elevator pitch (3 bullets), three concrete code sketches (V1 declaration; add V2 + upcaster; decode old V0 record at the latest version), five strengths backed with file:line references, six concerns (GHC version lock, type-level boilerplate, kiroku coexistence, SymTransducer `co` friction, RegFile snapshot serialization not addressed, learning curve), and a per-pattern selective-borrowing map. The evaluation file is referenced by the M2 design doc.
- [x] M0.2 — 2026-05-05: Verdict — **selectively borrow** (recorded in this plan's Decision Log below). The patterns to adopt: consecutive upcasters, an explicit per-event version vector (as a list of payload-version parsers, not a type family), and the test discipline (roundtrip + golden tests per declared version, generated via a thin helper rather than hindsight's type-level walker). Rejected: the type-level machinery (`MaxVersion`/`Versions` type families, Peano-numbered `Upcast n` instances, `SomeLatestEvent` wrapper, hindsight's own `EventStore` abstraction). Justification: keiro is Postgres-only and already has a kiroku-side `event_type` text registry, so hindsight's Symbol-to-Text translation layer would be redundant; keiki's `SymTransducer co` already supplies a domain sum of constructors and double-wrapping into hindsight's `SomeLatestEvent` adds 20-30 lines of glue per aggregate. The existing `Codec e` shape sketched in this plan already matches the value-level translation; no revision needed before M1.
- [x] M1.1 — 2026-05-05: Bootstrapped `spikes/codec/` cabal package (`spike.cabal`, `cabal.project`). Library depends on aeson, kiroku-store, text, containers. Executable adds QuickCheck, ephemeral-pg, hasql, hasql-pool, effectful. The package builds under the same nix dev shell as `spikes/command-cycle/` (keiki flake for GHC 9.12.3 + cabal; PATH-prepended Postgres 18 from kiroku flake).
- [x] M1.2 — 2026-05-05: Implemented `Codec e` in `src/Spike/Codec.hs` as a record of (`codecEncode`, `codecDecode`, `codecTypeTag`, `codecVersion`, `codecUpcasters`). Helpers `encodeForAppend`, `decodeRecorded`, `decodeRaw`, `migrateToCurrent`. `DecodeError` distinguishes UnknownVersion / UpcasterError / DecodeFailed / GapInUpcasterChain. Schema version recorded in `EventData.metadata.schemaVersion :: Int` (default 1 if missing).
- [x] M1.3 — 2026-05-05: Sample domain `Spike.Order` with `OrderEvent = OrderPlaced OrderPlacedData | OrderCancelled OrderCancelledData`. v2 OrderPlaced has `orderTotalCents :: Int` and `orderCurrency :: Text`; v1 had `orderTotal :: Int` (dollars) and no currency. `upcastV1ToV2` multiplies dollars by 100 and defaults currency to USD. Other constructors (OrderCancelled) pass through unchanged — they had no v1.
- [x] M1.4 — 2026-05-05: `app/Main.hs::scenarioRoundTrip` writes a hand-crafted v1-shaped JSON event (`{"tag":"OrderPlaced","contents":{"orderId":"ord-1","orderTotal":10}}` with `metadata.schemaVersion = 1`) directly via `appendToStream`. Reads back via `readStreamForward`, decodes through `decodeRecorded orderCodec`, asserts the result is `OrderPlaced { orderId = "ord-1", orderTotalCents = 1000, orderCurrency = "USD" }`. Acceptance log: `[codec-spike] decoded v1 → OrderPlaced (OrderPlacedData {orderId = "ord-1", orderTotalCents = 1000, orderCurrency = "USD"})`.
- [x] M1.5 — 2026-05-05: Same scenario also writes a v2 event natively via `encodeForAppend orderCodec`, then decodes it through the same path; assertion holds. Adds an OrderCancelled event in the same stream to prove the codec composes across multiple constructors.
- [x] M1.6 — 2026-05-05: `app/Main.hs::scenarioStressTest` generates 10 000 random `OrderEvent`s via QuickCheck `Arbitrary`, batches them 500-at-a-time through `appendToStream` with `ExactVersion` chaining, reads them back, decodes via `decodeRecorded orderCodec`, asserts decoded list equals source list. Acceptance log: `[codec-spike] stress test: 10000 events round-tripped`.
- [x] M2.1 — 2026-05-05: Wrote `docs/research/07-codec-strategy.md`. 14 sections covering: problem statement; the `Codec e` interface (every field's responsibility); type-tag convention (stable across schema versions, PascalCase, registered exactly once per codec, no reuse across aggregates); schema-version convention (under `EventData.metadata.schemaVersion`, default 1 when missing); upcaster chain ordering (ascending and contiguous, value-level pure JSON migrations); unknown-event policy (default fatal); integration with EP-1's `runCommand` (the production `EventStream` carries `esEventCodec :: Codec co`); separation from EP-4's snapshot codec (different lifecycle, different versioning); generic-deriving option for ergonomics; testing strategy (roundtrip property + golden tests per old version + version-vector exhaustiveness); the hindsight prior-art evaluation outcome (selectively borrow, with explicit per-pattern rationale); two upstream gaps for EP-6 (keiki RegFile serialization helper; reiterates EP-1's compile-time `solveOutput` constraint request); and three keiro-side production-library follow-ups (generic codec helper, tasty test-tree composer, type-tag registry).
- [x] M2.2 — 2026-05-05: Cross-referenced from `docs/research/00-overview.md` (one-line entry under the Document Index).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use a record-of-functions `Codec e` rather than a typeclass.
  Rationale: A record allows multiple codecs for the same type (different schema versions, different binary formats for testing), which a typeclass would forbid. It also keeps codecs first-class values that can be composed and stored. Aligns with keiki's overall preference for record-of-functions over typeclasses.
  Date: 2026-05-04.

- Decision: Encode the schema version in `EventData.metadata`, not in the type-tag string.
  Rationale: Keeping the type tag stable across schema versions means projections subscribed by `eventType` keep working without changes when the payload shape evolves. The metadata field is a JSONB column already present in kiroku (`Kiroku.Store.Types.EventData.metadata :: Maybe Aeson.Value`).
  Date: 2026-05-04.

- Decision: Upcasters are pure functions `Aeson.Value -> Either String Aeson.Value` indexed by source version, applied at decode time before the type-level decoder.
  Rationale: Matches the recommendation in keiki's schema-evolution note (summarized in `docs/research/02-keiki-decide-loop.md`). Pure functions are straightforward to test; placing the upcaster *before* the typed decoder means keiki always sees the current schema.
  Date: 2026-05-04.

- Decision: Use Aeson for the wire format in v1.
  Rationale: Kiroku stores `Aeson.Value` directly; switching to a binary format would require kiroku-side changes. The codec interface is parameterised so a future binary format (CBOR, MessagePack) can be introduced without API breakage.
  Date: 2026-05-04.

- Decision: Default unknown-event policy is **fatal** (every replayed event must be decodable).
  Rationale: The prior-art survey (`docs/research/05-workflow-prior-art.md`) shows silent skipping has caused production bugs. Override per aggregate when truly necessary, with a Decision-Log entry justifying the override.
  Date: 2026-05-04.

- Decision: M0 hindsight verdict — **selectively borrow**. Adopt three patterns from `/Users/shinzui/Keikaku/hub/haskell/hindsight`: (a) the consecutive-upcaster idea, expressed as a value-level `[(Int, Aeson.Value -> Either String Aeson.Value)]` chain whose entries map version `n` to version `n+1`; (b) the per-event version-vector concept, expressed as a value-level `Map Int (Aeson.Value -> Either String e)` (or equivalently the explicit `codecDecode` plus the upcaster chain — both shapes encode the same information); (c) the test discipline of generating roundtrip-and-golden tests per declared version. Reject the type-level machinery (`MaxVersion`/`Versions` type families, Peano-numbered `Upcast n` instances, the `SomeLatestEvent` existential wrapper, the `MigrateVersion` automatic composition). Reject also hindsight's own `EventStore` and subscription abstraction layers — keiro's storage is kiroku-store and its subscription engine is shibuya, both of which already expose the contract keiro needs. The full evaluation lives at `spikes/codec/notes/hindsight-evaluation.md`.
  Rationale: Hindsight's compile-time exhaustiveness *does* catch versioning bugs the value-level chain cannot — but at the cost of (i) double-wrapping the keiki domain sum into `SomeLatestEvent`, adding 20-30 lines of glue per aggregate; (ii) maintaining a parallel type-level event registry alongside kiroku's existing runtime `event_type` text column; (iii) a heavier syntax tax (~20 lines per event including type-instance declarations vs ~6 for the value-level shape); and (iv) a GHC ≥9.10 floor, which is fine for keiro today but reduces optionality. None of these benefits are worth their cost in keiro's narrower scope: Postgres-only, single-store, Aeson-only wire format, with kiroku already owning the type-tag registry. The borrowed patterns capture hindsight's actual design insight (separate event identity from payload version, compose consecutive upcasts, test every version) without paying for the type-level enforcement. Tradeoff acknowledged: keiro's value-level chain enforces "every version has an upcaster" at *runtime* (a `Nothing` from a missing chain entry causes a decode failure), where hindsight enforces it at compile time. Mitigation: M1's spike will exercise the chain on a multi-version event (V1→V2), and M2's design doc mandates a per-codec property test that asserts every supported version round-trips.
  Date: 2026-05-05.


## Outcomes & Retrospective

**Outcome (2026-05-05).** EP-2 delivered everything its purpose statement promised:

1. A working spike at `spikes/codec/` that round-trips a sample `Order` aggregate's events through a value-level `Codec e` record under real Postgres + `kiroku-store`. Scenario 1 verifies a deliberately v1-shaped JSON record (carrying `metadata.schemaVersion = 1`) decodes through the upcaster chain into the latest typed shape; scenario 2 round-trips 10 000 random `OrderEvent`s through `encodeForAppend` / `decodeRecorded`. Final transcript line: `[codec-spike] OK`.
2. A self-contained design document at `docs/research/07-codec-strategy.md` that fixes the `Codec e` interface, the type-tag and schema-version conventions, the upcaster chain ordering, the unknown-event policy, the testing strategy (roundtrip + golden + exhaustiveness), and the integration with EP-1, EP-3, and EP-4. The hindsight prior-art evaluation lives at `spikes/codec/notes/hindsight-evaluation.md` with an explicit per-pattern rationale for the "selectively borrow" verdict.

**Gaps and lessons.**

- **Hindsight's compile-time exhaustiveness is real but expensive.** The evaluation in `spikes/codec/notes/hindsight-evaluation.md` measured ~20+ lines per event (type-instance declarations + `SomeLatestEvent` glue) for hindsight vs ~6 lines per event for the value-level `Codec e`. The compile-time guarantees fall on the value-level side via the testing strategy — every codec must ship a roundtrip property test, a golden test per supported old version, and a version-vector exhaustiveness test. Without that discipline the value-level chain is genuinely less safe than hindsight; with it, the safety is equivalent.
- **kiroku's existing `event_type` text registry was the deciding factor against hindsight.** Hindsight's type-level Symbol identity would have forced a Symbol-to-Text translation layer at every kiroku boundary, undoing the benefit of an indexed text column. The value-level codec rides directly on what kiroku already provides.
- **EP-1's M1 spike's `esEncode`/`esDecode` pair will be replaced by `esEventCodec :: Codec co`.** This is a mechanical renaming when the production keiro library lands; the spike does not need to be retroactively updated. The forward reference is recorded in `docs/research/06-command-cycle-design.md` §4 (the production API).
- **One keiki upstream gap surfaced**: EP-4's snapshot codec needs a `RegFile rs <-> Aeson.Value` helper that walks the slot list and serializes each slot from its `ToJSON`/`FromJSON` instance. EP-2 does not need it (events use the simple `Codec e` shape) but EP-4 will. Forwarded to EP-6.

**Comparison against the original purpose.** EP-2's purpose was to fix the codec layer between kiroku's untyped JSON storage and keiki's typed domain events, including schema evolution. The contract is fixed, the upcaster chain is proved implementable on a real schema migration (v1 dollars → v2 cents + currency), the test discipline replaces hindsight's compile-time guarantees with a runtime + test-suite equivalent, and EP-3 / EP-4 / EP-6 have explicit forward references for what they consume. No revision of EP-1's contract was needed; the codec slot has been there since EP-1's M2 design doc.


## Context and Orientation

Repository layout. Working tree at `/Users/shinzui/Keikaku/bokuno/keiro`. Sister projects relevant here:

- `kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Stores `EventData.payload :: Aeson.Value`, `EventData.metadata :: Maybe Aeson.Value`, `EventData.eventType :: Text`. See `docs/research/01-kiroku-read-side.md`.
- `keiki` at `/Users/shinzui/Keikaku/bokuno/keiki`. Works on typed domain events `co` (the output alphabet of `SymTransducer phi rs s ci co`); explicit non-goal of keiki is to ship serialization (see `docs/research/02-keiki-decide-loop.md`).

Term definitions:

- *Codec* — a value of type `Codec e` carrying functions to convert between Haskell `e` values and JSON `Aeson.Value`s, plus metadata describing the wire-format identity and version.
- *Event-type tag* — a stable text string (e.g., `"OrderPlaced"`) recorded in `EventData.eventType`. It identifies the *kind* of event for filtering and routing. It does **not** encode schema version.
- *Schema version* — a positive integer recorded in `EventData.metadata` under a fixed key (`"schemaVersion"`). It identifies the *shape* of the payload for that type. Default is 1 when missing.
- *Upcaster* — a pure function `Aeson.Value -> Either String Aeson.Value` that transforms a payload from one schema version to the next. Upcasters are composed: to upcast from v1 to v3, run the v1→v2 upcaster then the v2→v3.
- *Unknown event* — a `RecordedEvent` whose `eventType` does not appear in any registered codec. The default policy is fatal.

What does **not** exist today:

- Any `Codec` interface in keiro, kiroku, or keiki.
- Any standard for placing the schema version on events.
- Any upcaster framework.
- Any test fixtures of "old-shape JSON we have to keep decoding".

Kiroku already supports the necessary primitives: `EventData.eventType`, `EventData.metadata`, the JSONB column types, and `RecordedEvent.payload :: Aeson.Value` so the decoder receives the raw shape without lossy wrapping.


## Plan of Work

Two milestones. Each independently verifiable.

### Milestone 1 — Working codec spike

A Haskell package `spikes/codec/` demonstrates a typed event sum being encoded to `Aeson.Value`, persisted to kiroku, read back through `readStreamForward`, decoded through an upcaster, and reconstructed at the latest schema version.

Steps:

1. **Package setup.** `spikes/codec/spike.cabal`, `spikes/codec/cabal.project` (referencing local kiroku and keiki checkouts), `spikes/codec/app/Main.hs`, `spikes/codec/src/Spike/Codec.hs`, `spikes/codec/src/Spike/Order.hs`. Depends: `kiroku-store`, `keiki`, `aeson`, `text`, `vector`, `effectful`, `ephemeral-pg`, `QuickCheck`.
2. **The `Codec` value.** In `Spike.Codec`:

       data Codec e = Codec
         { codecEncode    :: e -> Aeson.Value
         , codecDecode    :: Aeson.Value -> Either String e        -- decodes the *current* schema version
         , codecTypeTag   :: e -> Text                              -- stable, version-independent
         , codecVersion   :: Int                                    -- current schema version, e.g. 2
         , codecUpcasters :: [(Int, Aeson.Value -> Either String Aeson.Value)]
             -- entry (n, f) upcasts from version n to version n+1; entries must be ascending and contiguous
         }

   Provide a helper `decodeRecorded :: Codec e -> RecordedEvent -> Either String e`:
   - extract schema version from `metadata` (default 1 if missing — accommodates legacy events that predate the convention),
   - compose the relevant upcasters in order,
   - run `codecDecode` on the result.
3. **Sample domain.** In `Spike.Order`:

       data OrderEvent
         = OrderPlaced { orderId :: Text, orderTotalCents :: Int, orderCurrency :: Text }
         | OrderCancelled { orderId :: Text, cancelReason :: Text }
         deriving (Eq, Show, Generic)

   Hand-write the `Codec OrderEvent` rather than deriving generically — the spike is a feasibility check, not an ergonomics study (deferred to the design doc).
   Schema migration drama: imagine v1's `OrderPlaced` had only `{orderId, orderTotal}` (an `Int` of dollars). v2 replaces it with `{orderId, orderTotalCents, orderCurrency}`. Write the v1→v2 upcaster:

       upcastV1ToV2 :: Aeson.Value -> Either String Aeson.Value
       upcastV1ToV2 (Object o) = case (lookup "orderId" o, lookup "orderTotal" o) of
         (Just oid, Just (Number d)) -> pure $ Object (insert "orderTotalCents" (Number (d * 100)) ...)
         _ -> Left "v1 OrderPlaced missing fields"
4. **Round-trip.** In `app/Main.hs`:
   - start `ephemeral-pg`, apply kiroku schema, build `KirokuStore`,
   - encode and append a v1-shaped JSON manually (mimicking a record from a previous deploy) — `metadata.schemaVersion = 1`,
   - encode and append a v2-shaped event via the live codec — `metadata.schemaVersion = 2`,
   - read the stream back via `readStreamForward`,
   - decode each `RecordedEvent` via `decodeRecorded codec`,
   - assert both decode to `OrderPlaced` values whose totals are in cents.
5. **Stress test.** Generate 10 000 `OrderEvent` values via `QuickCheck`, encode → write → read → decode, assert the decoded list equals the source list.

Acceptance for M1: `cabal run spike` exits 0 and prints `OK` after both the round-trip and the stress test pass.

### Milestone 2 — Design document

Write `docs/research/07-codec-strategy.md`. Self-contained. Structure:

- *Problem statement* — typed domain vs untyped storage; schema evolution as a first-class concern.
- *Codec interface* — final shape of `Keiro.Codec.Codec e`. Justify each field.
- *Type-tag convention* — text identifier rules (PascalCase domain term, unchanged across schema versions, registered exactly once per codec). Prohibit reuse across aggregates.
- *Schema-version convention* — JSON object at `metadata.schemaVersion :: Int`, default 1 for missing. Explain why metadata rather than payload.
- *Upcaster ordering* — explicit `[(Int, Value -> Either String Value)]` chain; ordering rule: ascending and contiguous; gaps are forbidden.
- *Unknown-event policy* — three options (skip-and-warn, fatal, quarantine) with the v1 default being **fatal**. Document how to override per-aggregate.
- *Integration with `runCommand` (EP-1)* — the encoder/decoder slot in EP-1's spike `runCommand` should be replaced by a `Codec e` argument. Show the updated signature.
- *Integration with snapshots (EP-4)* — note that snapshot serialization is a separate concern (snapshot encodes the joint state `(s, RegFile rs)` of the `SymTransducer`, not events) and a separate `StateCodec (s, RegFile rs)` is acceptable; cross-link forward. The register-file half is non-trivial because `RegFile rs` is a typed heterogeneous tuple — keiki may need to expose a serialization helper. Forward to EP-6.
- *Generic-deriving option* — discussion of whether to provide a default `Codec e` derived from `Generic e` and `ToJSON`/`FromJSON`. v1 recommendation: yes, as a convenience helper, with the explicit-codec form remaining the canonical interface.
- *Testing strategy* — every codec must have a property test asserting `decode . encode == Right`, plus a fixture file per supported old schema version.
- *Prior art: hindsight* — summarize how `hindsight` (`/Users/shinzui/Keikaku/hub/haskell/hindsight`) handles the same problem: events identified by a type-level `Symbol`; `MaxVersion event :: Nat` + `Versions event :: [Type]` type families declaring the version vector; one `Upcast n event` instance per consecutive transition automatically composed by a default `MigrateVersion` instance into a single migrate-to-latest function; a `parseMap` that produces a `Map Int (Value -> Parser CurrentPayloadType)` covering every supported version; the test toolkit at `Test.Hindsight.Generate` that derives roundtrip and golden tests for every declared version. Compare against the value-level `[(Int, Value -> Either String Value)]` chain currently sketched in this plan. State the verdict reached at M0.2 — adopt, selectively borrow (e.g., adopt the consecutive-upcast composition pattern but keep value-level codecs), or reject — and justify it against keiro's specific constraints: keiki's domain output type is `co` from `SymTransducer phi rs s ci co` (not a per-event `Symbol`); kiroku already keys events by a runtime `EventData.eventType :: Text`, not a type-level name; the snapshot codec must serialize `(s, RegFile rs)` where `RegFile rs` is a typed heterogeneous tuple. If the verdict is "borrow", name exactly which pieces and how they map onto keiro's value-level codec; if "reject", identify which of hindsight's properties (compile-time exhaustiveness, missing-upcast errors at compile time, automatic test generation) keiro forgoes and what mitigations replace them.
- *Open questions / upstream gaps* — record any kiroku-side change needed (likely none — `EventData.metadata` already exists). If the hindsight verdict is "adopt" or "selectively borrow", record any keiki-side gap that the borrowed mechanism reveals (e.g., `RegFile rs` serialization, which is already a known request).

Acceptance for M2: doc exists at `docs/research/07-codec-strategy.md`, is referenced from `docs/research/00-overview.md`, and a reviewer can answer "how does keiro handle a 5-year-old event whose payload shape no longer matches?" purely from this document.


## Concrete Steps

Working directory `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

Bootstrap and run the spike:

    mkdir -p spikes/codec/app spikes/codec/src/Spike
    # author files per Plan of Work milestone 1
    cd spikes/codec
    cabal build all
    cabal run spike

Expected (truncated):

    [codec-spike] starting ephemeral-pg ...
    [codec-spike] applied kiroku schema
    [codec-spike] wrote v1-shaped event
    [codec-spike] wrote v2-shaped event
    [codec-spike] decoded v1 → OrderPlaced {orderId="ord-1", orderTotalCents=1000, orderCurrency="USD"}
    [codec-spike] decoded v2 → OrderPlaced {orderId="ord-2", orderTotalCents=4250, orderCurrency="EUR"}
    [codec-spike] stress test: 10000 events round-tripped
    [codec-spike] OK

Write the design doc:

    # author docs/research/07-codec-strategy.md
    # then update docs/research/00-overview.md to add the new entry


## Validation and Acceptance

All must hold:

1. `cabal build all` from `spikes/codec` exits 0.
2. `cabal run spike` exits 0 and prints `OK`.
3. The spike decodes a deliberately v1-shaped JSON to the v2 typed value and the values are equal at the v2 representation.
4. The stress test successfully round-trips at least 10 000 events.
5. `docs/research/07-codec-strategy.md` exists and is referenced from `docs/research/00-overview.md`.
6. The design document fixes the encoder/decoder argument shape `runCommand` will adopt; EP-1's design doc (`docs/research/06-command-cycle-design.md`) must be updated to consume that shape (or this plan must record the inconsistency in Surprises & Discoveries and propose resolution).


## Idempotence and Recovery

The spike is throwaway. Every run starts a fresh `ephemeral-pg`. Re-running is safe.

If the upcaster chain in the spike rejects a v1-shaped event, that is a real bug — fix the upcaster, do not relax the unknown-event policy. The fatal default is intentional.

The design document is a normal Markdown file; saving the same content twice is a no-op.


## Interfaces and Dependencies

Libraries used:

- `kiroku-store` — stores `Aeson.Value` payloads and metadata. We do not modify kiroku in this plan; any required upstream change is forwarded to EP-6.
- `keiki` — defines the typed domain events; the codec lives between keiki and kiroku.
- `aeson` — wire format.
- `effectful`, `ephemeral-pg`, `vector`, `text`, `QuickCheck` — supporting infrastructure for the spike.

Function signatures that must exist by the end of M1:

    -- spikes/codec/src/Spike/Codec.hs
    data Codec e = Codec
      { codecEncode    :: e -> Aeson.Value
      , codecDecode    :: Aeson.Value -> Either String e
      , codecTypeTag   :: e -> Text
      , codecVersion   :: Int
      , codecUpcasters :: [(Int, Aeson.Value -> Either String Aeson.Value)]
      }

    decodeRecorded :: Codec e -> RecordedEvent -> Either String e

    encodeForAppend :: Codec e -> e -> EventData
      -- sets payload, eventType, and metadata.schemaVersion = codecVersion;
      -- leaves eventId = Nothing so kiroku assigns a UUIDv7

By the end of M2, `docs/research/07-codec-strategy.md` is the source of truth for these signatures and EP-1 (`docs/plans/1-command-cycle-design-and-spike.md`) is updated to consume the codec value rather than separate encoder/decoder slots.

Downstream consumers (must be informed of any signature change):

- EP-1 (command cycle) — keiro's `EventStream phi rs s ci co` record carries a `Codec co` and a `StateCodec (s, RegFile rs)`. The spike may inline the codec functions for brevity but must not drift from this plan's API.
- EP-3 (subscriptions/projections) — projection handlers and process-manager handlers consume `Codec co` to decode `RecordedEvent.payload`.
- EP-4 (snapshots) — uses an analogous `StateCodec (s, RegFile rs)` for snapshot serialization; design doc cross-links and (because `RegFile rs` is keiki-internal) records the serialization helper as a likely keiki-side request.
- EP-6 (upstream roadmap) — records any kiroku/keiki changes proposed by this plan: no kiroku changes; one keiki request — a register-file serialization helper (`RegFile rs <-> Aeson.Value`) so `StateCodec` can be derived rather than hand-built.


## Revisions

- 2026-05-04: Replaced `Decider`-language with `SymTransducer`-language throughout (`Codec e` becomes `Codec co` in the keiki sense; the snapshot codec is `StateCodec (s, RegFile rs)`, not `Codec s`). Added a keiki-side register-file serialization request to the downstream-consumers list. Reason: keiro's contract with keiki is the native `SymTransducer`, not the `Decider` facade — so the codec must serialize the transducer's actual state, including its register file.

- 2026-05-05: Added a prior-art evaluation phase (Progress M0.1 / M0.2) requiring a documented review of the `hindsight` Haskell library at `/Users/shinzui/Keikaku/hub/haskell/hindsight` before the spike or design doc commits to a codec API. Extended the design-doc outline with a "Prior art: hindsight" section that must summarize hindsight's compile-time versioning machinery (`MaxVersion` / `Versions` type families, consecutive `Upcast n` composition into `MigrateVersion`, `parseMap`, and the `Test.Hindsight.Generate` test toolkit) and record an explicit verdict. M1's spike API and M2's design doc are now gated on the M0.2 verdict — if the verdict is "adopt", the `Codec e` shape sketched in this plan must be revised before M1 starts. Reason: user flagged hindsight as potentially useful but uncertain; without an explicit research checkpoint the question would silently default to the simpler value-level upcaster chain. See the parent MasterPlan's 2026-05-05 Decision Log entry and Revisions note for the higher-level framing.
