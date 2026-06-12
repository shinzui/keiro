---
id: 68
slug: harden-keiro-core-codec-and-stream-contracts
title: "Harden keiro-core codec and stream contracts"
kind: exec-plan
created_at: 2026-06-11T04:45:56Z
master_plan: "docs/masterplans/9-keiro-production-readiness-hardening.md"
---

# Harden keiro-core codec and stream contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro is an event-sourcing framework: services append domain events (JSON payloads tagged with an event-type string) to streams in PostgreSQL, and later read them back and decode them into Haskell values. The `keiro-core` package owns the contracts that every other package builds on: the `Codec` (how events are serialized, versioned, and migrated), the `Stream`/`StreamCategory` naming API, the snapshot policy, and the public integration-event envelope that crosses service boundaries over Kafka.

A June 2026 production-readiness audit found that these contracts leak correctness hazards. The worst (finding H1) is that a codec's `decode` function never sees the event-type tag that was stored next to the payload, so every multi-event codec must duplicate a discriminator (a `"kind"` field) inside the payload — and when the stored tag and the payload's `"kind"` disagree, an event silently decodes as the *wrong constructor*. After this plan, the stored tag is threaded into `decode` and into upcasters (payload migrations), so the wire tag is authoritative and a shape-compatible payload can never masquerade as a different event. This is the **one intentionally breaking API change of the entire hardening initiative** (see the master plan's Decision Log at `docs/masterplans/9-keiro-production-readiness-hardening.md`); doing it now, before more downstream codecs exist, is deliberate.

Around that breaking change, this plan folds in a set of additive contract hardenings: a `mkCodec` smart constructor that rejects misconfigured codecs at startup instead of at first decode of an old event; loud errors for future-versioned payloads (a rollback hazard) and malformed schema-version stamps (today silently treated as version 1, replaying upcasters against current-shape payloads); closing the `StreamCategory "$all"` validation bypass; an `occurredAt`/`attributes` round-trip for integration events over Kafka (today the consumer silently substitutes its own receive time); accepting `application/json; charset=utf-8`; and snapshot-policy coherence (today `Every 10` with no state codec silently never snapshots).

When the plan is done, you can see it working by running the test suites listed in Validation and Acceptance: a new regression test proves a tag/payload disagreement decodes by tag; `mkCodec` rejects a gappy upcaster chain at construction; a Kafka header round-trip preserves the producer's `occurredAt`; and the whole repository (all seven packages in `cabal.project`) still builds and passes.


## Progress

- [ ] M1.1: Change `Codec`/`Upcaster`/`CodecError` in `keiro-core/src/Keiro/Codec.hs` (tag threading, `EventType` fields, `VersionAhead`, `IncompleteUpcasterChain`).
- [ ] M1.2: Update `decodeRaw`, `migrateToCurrent`, `decodeRecorded`, `encodeForAppendWithMetadata` internals for the new shapes.
- [ ] M1.3: Update codec definitions in `keiro/src/Keiro/Workflow/Types.hs` (workflowJournalCodec).
- [ ] M1.4: Update codec definitions and call sites in `keiro/test/Main.hs` (orderCodec, gappyCodec, counterCodec, decodeRaw calls, UnknownEventType expectation).
- [ ] M1.5: Update the six jitsurei codecs (`jitsurei/src/Jitsurei/{OrderStream,Incident,Paging,FulfillmentProcess,EscalationProcess,AgentQualRouter}.hs`) to tag-dispatching decoders.
- [ ] M1.6: Update `jitsurei/test/Main.hs` (decodeRaw call) and `jitsurei/app/Main.hs` if needed (decodeRecorded callers compile unchanged).
- [ ] M1.7: Update `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` (`keiroJobCodec` envelope gains a `"t"` tag field).
- [ ] M1.8: Update keiro-dsl codegen (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` codec emission, `keiro-dsl/src/Keiro/Dsl/Harness.hs` decodeRaw emission).
- [ ] M1.9: Update the nine checked-in generated codec fixtures plus the conformance-v2 harness under `keiro-dsl/test/conformance*/`.
- [ ] M1.10: Add the H1 regression test (tag-vs-kind disagreement) to `keiro/test/Main.hs`; full build green.
- [ ] M2.1: Add `CodecConfigError` and `mkCodec` to `keiro-core/src/Keiro/Codec.hs`.
- [ ] M2.2: Change `extractSchemaVersion` and `metadataFor` to return `Either CodecError`; add `MalformedSchemaVersionStamp` and `NonObjectCallerMetadata`.
- [ ] M2.3: Implement `VersionAhead` guard in `migrateToCurrent`; replace the truncated-chain `UnknownVersion` misuse with `IncompleteUpcasterChain`.
- [ ] M2.4: Update the two `metadataFor` call sites in `keiro/test/Main.hs` and the `extractSchemaVersion` assertion; add mkCodec/VersionAhead/malformed-stamp tests.
- [ ] M3.1: Hide the `StreamCategory` constructor; export `categoryText`; fix `keiro/test/Main.hs:335-341`.
- [ ] M3.2: `categoryUnsafe` gains `HasCallStack` and a descriptive error.
- [ ] M3.3: `entityStream`/`entityStreamId` reject empty/whitespace id segments (`HasCallStack` error).
- [ ] M3.4: `category` rejects whitespace/control characters (`CategoryContainsIllegalChar`); doc warning on raw `stream`.
- [ ] M3.5: Stream tests updated/added; build green.
- [ ] M4.1: Add `Terminality` to `keiro-core/src/Keiro/EventStream.hs`; thread it through `Custom` and `shouldSnapshot`; fix `Every` at version 0.
- [ ] M4.2: Update the three `shouldSnapshot` call sites (`keiro/src/Keiro/Command.hs:555`, `keiro/src/Keiro/Workflow.hs:442,490`).
- [ ] M4.3: `mkEventStream` rejects snapshotPolicy-without-stateCodec; tests added.
- [ ] M5.1: Emit `keiro-occurred-at` and `keiro-attributes` headers in `keiro-core/src/Keiro/Integration/Event.hs`.
- [ ] M5.2: Parse them in `keiro/src/Keiro/Inbox/Kafka.hs` (new `InvalidTimeHeader`/`InvalidJsonHeader` errors, receivedAt fallback).
- [ ] M5.3: Strip media-type parameters in `parseContentType`; tests for charset and the occurredAt/attributes round-trip.
- [ ] M6.1: Full-repo verification (`cabal build all --enable-tests`, all suites, `just haskell-test`); haddock pass over changed modules.
- [ ] M6.2: Update this plan's living sections and tick the three EP-2 rollup lines in `docs/masterplans/9-keiro-production-readiness-hardening.md`.


## Surprises & Discoveries

- The H1 blast radius is smaller than the master plan implies on the read path: `decodeRecorded :: Codec e -> RecordedEvent -> Either CodecError e` keeps its signature (it already holds the `RecordedEvent` and can pull the tag itself), so `keiro/src/Keiro/Command.hs` and `keiro/src/Keiro/Workflow.hs` — which only call `decodeRecorded` and `encodeForAppendWithMetadata` — need **no edits for H1**. The break surfaces at the fourteen in-repo `Codec { ... }` record literals and at the callers of `decodeRaw`/`migrateToCurrent` (`jitsurei/test/Main.hs:42`, `keiro-pgmq/src/Keiro/PGMQ/Codec.hs:61-62`, keiro-dsl generated harnesses). Recorded here so the implementer does not hunt for phantom Command.hs changes; the master plan's EP-3 soft dependency (same module ordering) still stands.
- The keiro-dsl package (out of scope as a *feature* surface per the master plan) checks in **generated** Haskell fixtures that construct `Codec` literals: nine `Codec.hs` files under `keiro-dsl/test/conformance*/Generated/` plus the codegen templates in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` (function `emitCodecValue`, line ~887) and `keiro-dsl/src/Keiro/Dsl/Harness.hs` (function `upcastDecl`, line ~259). These break under H1 and must be mechanically updated for `cabal build all --enable-tests` to succeed. See Decision Log.

(More to be added during implementation.)


## Decision Log

- Decision: Final H1 signatures — `decode :: EventType -> Value -> Either Text e`, `type Upcaster = (Int, EventType -> Value -> Either Text Value)`, `eventTypes :: NonEmpty EventType`, `eventType :: e -> EventType`; `decodeRaw` and `migrateToCurrent` gain an `EventType` parameter; `decodeRecorded` is unchanged.
  Rationale: The tag must reach both the current decoder and every migration rung (an upcaster for a multi-event codec is just as tag-blind as decode). Keeping `Upcaster` a pair (not a record) and `decodeRecorded`'s signature minimizes churn: existing single-event upcasters become `(1, const upcastFoo)` and all `decodeRecorded` call sites compile unchanged. `eventTypes`/`eventType` move from `Text` to kiroku's `EventType` newtype (finding L4) in the same sweep because every comparison in the codec is against `RecordedEvent.eventType :: EventType`; doing it separately would mean touching the same fourteen record literals twice. `UnknownEventType`'s second field becomes `![EventType]` for the same reason.
  Date: 2026-06-11

- Decision: Decoders dispatch on the passed tag; the `"kind"` field stays in encoded payloads but is no longer read.
  Rationale: The wire tag (`RecordedEvent.eventType`, stored in its own column by kiroku) is the authoritative discriminator. Removing `"kind"` from payloads would change the wire shape of already-stored events for no safety gain; ignoring it on decode means a tag/`"kind"` disagreement now resolves to the tag — the defined-correct behavior — instead of silently honoring the payload. Dropping `"kind"` from *encode* is noted as future work (a wire-shape change needing its own upcaster story).
  Date: 2026-06-11

- Decision: Update keiro-dsl's codegen templates and checked-in generated fixtures in this plan, even though the master plan lists "the keiro-dsl toolchain" as out of scope.
  Rationale: The master plan's out-of-scope clause excludes *feature work* on the DSL; this plan's mandate that "the repo always builds" (and the master plan's own carve-out wording for jitsurei: "beyond whatever compile fixes the keiro-core codec signature change forces") applies equally to keiro-dsl, which is a `cabal.project` package whose conformance test suites construct `Codec` literals. Only mechanical compile fixes are made: `emitCodecValue`, `emitDecode`, `upcastersExpr`, `upcastDecl`, and the nine generated `Codec.hs` fixtures (plus the conformance-v2 `Harness.hs`). Hand-owned hole modules keep their `Value -> Either Text Value` upcaster shape via `const`-wrapping, so no hand-owned fixture code changes.
  Date: 2026-06-11

- Decision: `mkCodec :: Codec e -> Either CodecConfigError (Codec e)` — validate an already-built record rather than take positional arguments.
  Rationale: Mirrors the existing `mkEventStream :: ... -> Either [EventStreamWarning] (EventStream ...)` convention in `keiro-core/src/Keiro/EventStream/Validate.hs` and the master plan's config-validation integration point (`mkX :: ... -> Either XConfigError X`, raw constructor still exported but documented as unvalidated). A six-argument positional constructor would be error-prone for the very misconfigurations it guards against.
  Date: 2026-06-11

- Decision: `mkCodec` requires upcaster sources to be exactly the set `[1 .. schemaVersion - 1]` (no gaps, no duplicates, nothing out of range), plus `schemaVersion >= 1` and pairwise-distinct `eventTypes`.
  Rationale: The schema-version stamp defaults to 1 when absent (legacy events carry no stamp), so a codec can never prove that no version-1 payloads exist; any hole in `1..schemaVersion-1` is reachable. A codec with a deliberately partial chain (e.g. the negative-test `gappyCodec` in `keiro/test/Main.hs`) can still use the raw `Codec` record literal, which remains exported and documented as unvalidated.
  Date: 2026-06-11

- Decision: `migrateToCurrent` fails with `VersionAhead sourceVersion schemaVersion` when the stored version is strictly greater than the codec's; equality stays a pass-through. No tolerance flag.
  Rationale: A future-versioned payload means a newer writer exists (rollback or mixed fleet); feeding its payload to an older decoder is exactly the silent-corruption hazard M2 describes, and a "tolerance" escape hatch would reintroduce it. Sibling plan `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md` builds its "future-version payloads retry instead of dead-letter" behavior on this typed error.
  Date: 2026-06-11

- Decision: `extractSchemaVersion` distinguishes "absent" (legacy default 1) from "present but malformed" (`MalformedSchemaVersionStamp`, an error); `metadataFor` rejects non-object caller metadata (`NonObjectCallerMetadata`) instead of silently discarding it. Both change from plain values to `Either CodecError` results.
  Rationale: Absent metadata genuinely means "written before stamping existed" — defaulting to 1 is the documented contract. A present-but-unreadable stamp (string `"2"`, `2.5`, non-object metadata) means corruption or a foreign writer; guessing 1 replays upcasters against current-shape payloads. Both functions are exported helpers with only two in-repo call sites outside keiro-core (`keiro/test/Main.hs:368,389,529`), so the signature change is cheap now.
  Date: 2026-06-11

- Decision: H2 — stop exporting the `StreamCategory` data constructor (and its `categoryTextOf` field selector, which would re-enable record-update forgery); export a plain `categoryText` accessor instead. Keep `Stream (..)` and the unvalidated `stream :: Text -> Stream a` exported, with an explicit Haddock warning on `stream`; no `Unsafe` rename.
  Rationale: `StreamCategory`'s entire value is its validation invariant, and `category`/`categoryUnsafe` cover every construction need (in-repo uses at `keiro/test/Main.hs:336-341` are the only bare-constructor uses and are test assertions easily rewritten). `stream` is different: any `Text` is a *legal* kiroku stream name, so the function is total and merely bypasses category conventions; renaming it would churn ~40 call sites across `keiro/test/Main.hs`, keiro-dsl codegen, and a generated fixture for zero added safety. The `EventStream{..}` record escape hatch stays per its documented trade-off (`keiro-core/src/Keiro/EventStream/Validate.hs:14-16`).
  Date: 2026-06-11

- Decision: M8 — `entityStream`/`entityStreamId` gain `HasCallStack` and call `error` on an empty or all-whitespace id segment, rather than returning `Either`.
  Rationale: Ids at this boundary come from domain id renderers (`StreamIdSegment` instances; see the seven point-free builders in `jitsurei/src/`), never raw user input; an empty rendering is a programmer error of the same class `categoryUnsafe` guards. An `Either` return would force restructuring every aggregate's stream-builder composition for an error no caller can meaningfully handle, and would be a second de-facto breaking change beyond the budgeted one.
  Date: 2026-06-11

- Decision: M6 — keep `snapshotPolicy` and `stateCodec` as separate `EventStream` fields; `mkEventStream` (in `keiro-core/src/Keiro/EventStream/Validate.hs`) rejects the inconsistent combination (a policy other than `Never` with `stateCodec = Nothing`) with a new `EventStreamWarning`. The field-collapse option (`Maybe (SnapshotPolicy, StateCodec)`) is rejected.
  Rationale: The master plan's Decision Log budgets exactly one breaking API change for the whole initiative (the codec tag); collapsing fields would be a second one rippling through every in-repo `EventStream` literal (six in jitsurei, several in tests, the DSL scaffolder) and every future EP. The fail-fast smart constructor delivers the same loud-at-construction guarantee additively. The reverse combination (`Never` with a `stateCodec`) is harmless dead configuration and is not rejected.
  Date: 2026-06-11

- Decision: L3 — `Custom` snapshot predicates receive terminality, expressed via a new two-constructor type `Terminality = Terminal | NotTerminal` that also replaces the positional `Bool` in `shouldSnapshot`.
  Rationale: The audit called out both the missing flag and the boolean-blindness of the existing positional flag; fixing the former with another bare `Bool` would entrench the latter. There are zero in-repo `Custom` users (verified by grep: only `Never`, `Every`, `OnTerminal` appear), and the three `shouldSnapshot` call sites (`keiro/src/Keiro/Command.hs:555`, `keiro/src/Keiro/Workflow.hs:442,490`) currently pass bare `True`/`False` literals — the new type makes those sites self-documenting. This is a keiro-core-internal API adjustment with no stored-data impact; logged as a deliberate, zero-consumer widening of the breaking budget.
  Date: 2026-06-11

- Decision: M4 — round-trip *both* `occurredAt` (new `keiro-occurred-at` header, ISO-8601/RFC3339) and `attributes` (new `keiro-attributes` header, compact JSON) across the Kafka hop; the consumer falls back to `receivedAt` / `Nothing` when the headers are absent (in-flight messages from old producers).
  Rationale: Both fields are already persisted faithfully in the outbox and inbox tables (`keiro/src/Keiro/Outbox/Schema.hs`, `keiro/src/Keiro/Inbox/Schema.hs`); only the Kafka hop drops them, contradicting the envelope's "preserved verbatim through publish and consume" promise. Documenting the loss instead was rejected: `occurredAt` substitution corrupts consumer-side timestamps silently, and the header cost is negligible (headers are emitted only when populated, and `attributes` is optional).
  Date: 2026-06-11

- Decision: M5 — `parseContentType` strips media-type parameters (everything from the first `;`) before comparison; the optional `+json` structured-syntax suffix is **not** accepted.
  Rationale: `application/json; charset=utf-8` is the same media type and rejecting it is a plain bug. `application/foo+json` is a *different, more specific* contract; treating it as plain JSON would mask producer misconfiguration. No in-repo producer emits a suffixed type today. Noted as future work alongside L7/L9.
  Date: 2026-06-11

- Decision: Scope — no new keiro-core test suite; all coverage extends the existing `keiro` package suite at `keiro/test/Main.hs` (run with `cabal test keiro-test`).
  Rationale: That suite already hosts the `Keiro.Codec`, `Keiro.Stream`, `Keiro.EventStream`, and inbox-Kafka spec sections this plan extends (lines ~327-400, ~2030-2350), has the hspec + `keiro-test-support` fixture wiring, and keiro-core's pure contracts need nothing a fresh suite would add except a duplicated dependency footprint. Revisit if keiro-core ever needs to be tested in isolation from the keiro package.
  Date: 2026-06-11

- Decision: keiro-pgmq's `keiroJobCodec` envelope grows a `"t"` (event-type tag) field: encode writes `{ "v": n, "t": "<tag>", "data": ... }`; decode uses `"t"` when present, falls back to the codec's sole event type when `eventTypes` has exactly one entry, and fails with a clear message for tag-less payloads of multi-event codecs.
  Rationale: The PGMQ envelope has no kiroku column to carry the tag, so it must live in the JSON. The fallback keeps single-event job codecs (the common case) decoding legacy rows; a multi-event legacy row genuinely cannot be safely dispatched and must fail loudly. Queue backlogs are short-lived (jobs), so the legacy window is small. Deeper pgmq codec testing belongs to `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`.
  Date: 2026-06-11

- Decision: Out of scope, mentioned only as future work — L6 (`Keiro.Prelude` gaps), L7 (`encodeJsonIntegrationEvent` ergonomics), L9 (`SnapshotPolicy` Show instance), dropping the `"kind"` payload field, `+json` suffix acceptance.
  Date: 2026-06-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Everything in this section is verifiable from the working tree; all paths are repository-relative from `/Users/shinzui/Keikaku/bokuno/keiro`.

The repository is a `cabal.project` workspace of seven Haskell packages: `keiro-core` (pure contracts — the subject of this plan), `keiro` (the event-store runtime built on those contracts), `keiro-pgmq` (PostgreSQL job queues), `keiro-migrations`, `keiro-test-support` (test fixtures), `jitsurei` (a worked example service), and `keiro-dsl` (a spec-to-code scaffolder whose conformance test suites contain checked-in generated code). `keiro-core` itself has **no test suite** (see `keiro-core/keiro-core.cabal` — a single `library` stanza); its behavior is tested through the `keiro` package's suite at `keiro/test/Main.hs` (cabal target `keiro-test`) and through `jitsurei/test/Main.hs` (`jitsurei-test`). The repo's umbrella verification commands live in the `Justfile`: `just haskell-build` runs `cabal build all`, `just haskell-test` runs `cabal test keiro-test`, `cabal test jitsurei-test`, and a diagram check.

Key vocabulary, defined once:

- An **event** is a JSON payload plus an **event-type tag** (kiroku's `newtype EventType = EventType Text`, defined in the external `kiroku-store` dependency's `Kiroku.Store.Types`; it is stored in its own column). A **`RecordedEvent`** is an event as read back from the store, carrying the tag, the payload, optional metadata JSON, and positions.
- A **codec** (`keiro-core/src/Keiro/Codec.hs`, type `Codec e`) is the per-stream serialization contract: the allow-list of tags (`eventTypes`), a projection from a domain value to its tag (`eventType`), the current payload version (`schemaVersion`), `encode`/`decode`, and **upcasters** — a chain of pure migrations keyed by source version that rewrite a version-n payload into version-n+1 shape, replayed at read time (`migrateToCurrent`) so old payloads decode through the current decoder. The schema version is stamped into event metadata under the `"schemaVersion"` key on append (`metadataFor`) and read back on decode (`extractSchemaVersion`).
- A **stream** (`keiro-core/src/Keiro/Stream.hs`) is named `<category>-<id>`; the **category** is the substring before the first `-` and is how subscriptions target families of streams. `StreamCategory a` is a validated category (rejecting empty, `-`, and the reserved `$all`); `category` is the safe constructor, `categoryUnsafe` the partial one for literals, `entityStream cat id` renders the full name. Compound categories are written camelCase and `:` is reserved for the workflow family — deliberately *guidance, not validation* (see `docs/plans/66-add-safe-stream-construction-helpers-category-api-to-keiro-stream.md`, Decision Log, "camelCase" entry): do not tighten validation against `_`, `:`, or unicode.
- An **`EventStream`** (`keiro-core/src/Keiro/EventStream.hs`) bundles a pure keiki state machine with its codec, stream-name resolution, a **`SnapshotPolicy`** (`Never` / `Every n` / `OnTerminal` / `Custom`, evaluated by `shouldSnapshot` in `keiro-core/src/Keiro/Snapshot/Policy.hs`) and an optional **`StateCodec`** (snapshot serialization — a *separate* type from `Codec`, with its own un-tagged `decode :: Value -> Either Text state`; snapshots are single-shape so H1 does not touch it — verified against `keiro/src/Keiro/Snapshot/Codec.hs`, which only constructs `StateCodec`).
- An **integration event** (`keiro-core/src/Keiro/Integration/Event.hs`) is the public envelope crossing bounded contexts over Kafka: payload bytes plus metadata mapped to Kafka headers by `integrationHeaders`. The consumer side reconstructs the envelope from headers in `keiro/src/Keiro/Inbox/Kafka.hs` (`integrationEventFromKafka`); the producer side attaches them in `keiro/src/Keiro/Outbox/Kafka.hs`.

Where the audited defects live, re-verified against the current tree (line numbers from the tree at commit `9fa283b`):

- **H1**: `keiro-core/src/Keiro/Codec.hs:82` (`decode :: !(Value -> Either Text e)`), `:59` (`type Upcaster = (Int, Value -> Either Text Value)`), `:165-169` (`decodeRecorded` checks tag membership, then *discards* the tag). Consequence visible in every multi-event codec: e.g. `jitsurei/src/Jitsurei/Incident.hs:250-296` duplicates the tag as a `"kind"` payload field, and `keiro/test/Main.hs:4573-4600` (`counterCodec`) distinguishes constructors by sniffing an `"audited"` field — a recorded event tagged `CounterAudited` whose payload lacks that field silently decodes as `CounterAdded`.
- **M1**: no smart constructor; `schemaVersion >= 1` is only checked inside `encodeForAppendWithMetadata` (`Codec.hs:131-132`), duplicate upcaster keys are silently shadowed by `Prelude.lookup` (`:201`), chain gaps surface only when the first old event is read (`:203-205`).
- **M2**: `Codec.hs:193-194` — `sourceVersion >= schemaVersion -> Right payload` passes future-versioned payloads to the current decoder.
- **M3**: `Codec.hs:220-225` — `extractSchemaVersion` defaults *any* malformed stamp to 1; `Codec.hs:151-158` — `metadataFor` silently discards non-object caller metadata.
- **L1**: `Codec.hs:203-205` — a truncated chain (no later rung exists) is misreported as `UnknownVersion`.
- **H2**: `keiro-core/src/Keiro/Stream.hs:17` exports `StreamCategory (..)`, so `StreamCategory "$all"` compiles (used benignly at `keiro/test/Main.hs:336-341`). **M7**: `Stream.hs:94-95` — `categoryUnsafe` has no `HasCallStack` and errors with a raw `show`. **M8**: `Stream.hs:126-128` — `entityStream` accepts an empty id, contradicting its own doc (`:107-110`). **L8**: `Stream.hs:83-88` — `category` accepts whitespace/control characters.
- **M6**: `keiro-core/src/Keiro/EventStream.hs:54-55` — `snapshotPolicy = Every 10` with `stateCodec = Nothing` silently never snapshots (the runtime gate is `keiro/src/Keiro/Command.hs:547` matching on `stateCodec` first). **L2**: `keiro-core/src/Keiro/Snapshot/Policy.hs:30-32` — `Every n` returns `True` at version 0 (`0 mod n == 0`). **L3**: `EventStream.hs:74` — `Custom` predicates cannot see terminality.
- **M4**: `keiro-core/src/Keiro/Integration/Event.hs:174-204` — `integrationHeaders` emits no header for `occurredAt` or `attributes`; `keiro/src/Keiro/Inbox/Kafka.hs:120-129` substitutes `receivedAt` and hard-codes `attributes = Nothing` (with an apologetic comment). **M5**: `Integration/Event.hs:244-249` — `parseContentType` compares the whole string, so `application/json; charset=utf-8` becomes `OtherContentType` and `decodeJsonIntegrationEvent` (`:285-288`) rejects it as unsupported.

Downstream call-site inventory for the breaking change (complete; gathered by `grep` over all packages, excluding `dist-newstyle`):

- `Codec { ... }` record literals: `keiro/src/Keiro/Workflow/Types.hs:167`; `keiro/test/Main.hs:4271` (orderCodec), `:4285` (gappyCodec), `:4575` (counterCodec); `jitsurei/src/Jitsurei/OrderStream.hs:129`, `Incident.hs:252`, `Paging.hs:158`, `FulfillmentProcess.hs:182`, `EscalationProcess.hs:190`, `AgentQualRouter.hs:195`; generated fixtures `keiro-dsl/test/conformance{,-v2,-coldstart,-process,-process-runtime,-process-full}/Generated/*/*/Codec.hs` (nine files).
- `decodeRaw` callers: `keiro/test/Main.hs:375,379`; `jitsurei/test/Main.hs:42`; `keiro-dsl/test/conformance-v2/Generated/HospitalCapacity/Reservation/Harness.hs:42` (and its emitter `keiro-dsl/src/Keiro/Dsl/Harness.hs:266`).
- `migrateToCurrent` + raw `Codec.decode` access: `keiro-pgmq/src/Keiro/PGMQ/Codec.hs:61-62` (`keiroJobCodec`).
- `decodeRecorded`/`encodeForAppend*` callers (NO signature change, listed to show they need no edit): `keiro/src/Keiro/Command.hs:248,320,586`, `keiro/src/Keiro/Workflow.hs:593,741`, dozens of test assertions, `jitsurei/app/Main.hs:529,599,614`.
- `metadataFor` / `extractSchemaVersion` external callers (M3 signature change): `keiro/test/Main.hs:368,389,529`.
- `shouldSnapshot` callers (L2/L3): `keiro/src/Keiro/Command.hs:555` (passes `terminal :: Bool` computed from `Keiki.isFinal`), `keiro/src/Keiro/Workflow.hs:442` (literal `True`), `:490` (literal `False`).
- Bare `StreamCategory` constructor uses (H2): `keiro/test/Main.hs:336,339,341` only.

Sibling-plan coordination (reference by path only): `docs/plans/69-fix-event-store-command-path-snapshot-and-read-model-correctness.md` (EP-3) edits `keiro/src/Keiro/Command.hs` after this plan and builds against the final decode signature recorded in this plan's Interfaces section. `docs/plans/74-...job-workers-resilient.md` (EP-8) builds its future-version retry behavior on the `VersionAhead` error introduced here. The category API being hardened was introduced by `docs/plans/66-add-safe-stream-construction-helpers-category-api-to-keiro-stream.md`.


## Plan of Work

The work is six milestones. Milestone 1 is the breaking change and must land as one atomic commit-series (the repo does not build mid-way through it); milestones 2-5 are additive and independent of each other; milestone 6 is the final sweep. Run all commands from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`.


### Milestone 0 (baseline, no edits)

Before changing anything, prove the starting state is green so later failures are attributable. Run `cabal build all` and `cabal test keiro-test`; both must succeed (hspec ends with `N examples, 0 failures`). Optionally run `cabal build all --enable-tests` to pre-build the dsl conformance suites you will touch in M1. The test suites provision their own PostgreSQL via `keiro-test-support`/ephemeral-pg (suite-level template databases); no external database setup is needed.


### Milestone 1 — thread the event-type tag through Codec (H1 + L4), update every call site

Scope: the one breaking change. At the end, `Codec`'s `eventTypes`, `eventType`, `decode`, and `Upcaster` all speak `EventType`, the stored tag reaches the decoder and every upcaster rung, all fourteen in-repo codecs dispatch on the tag instead of a payload `"kind"` field, the keiro-dsl scaffolder generates the new shape, and a new regression test proves a tag/payload disagreement decodes by tag. The repo builds and all suites pass.

In `keiro-core/src/Keiro/Codec.hs`: change the `Upcaster` alias to `(Int, EventType -> Value -> Either Text Value)` and update its Haddock to say the migration receives the event-type tag; change the `Codec` fields to `eventTypes :: !(NonEmpty EventType)`, `eventType :: !(e -> EventType)`, `decode :: !(EventType -> Value -> Either Text e)`; change `UnknownEventType`'s second field to `![EventType]`. Add an `EventType` parameter to `decodeRaw` and `migrateToCurrent` (new signatures in Interfaces below) and thread it: `decodeRecorded` extracts `recorded ^. #eventType` and passes it; move the membership check from `decodeRecorded` into `decodeRaw` so both entry points enforce the allow-list (single-sourcing `isKnownEventType`); inside `migrateToCurrent`'s `go`, apply each rung as `upcast tag current`. `encodeForAppendWithMetadata` drops its `List.elem`-over-`Text` comparison in favor of comparing `EventType` values directly (the `EventType` wrapping at `:135,139` disappears since `eventType` now returns one). Update the module Haddock (`:1-18`) to describe tag-aware decoding.

Then update call sites in this order (each bullet leaves one package compiling):

1. `keiro/src/Keiro/Workflow/Types.hs` — `workflowJournalCodec`: wrap the five tags in `EventType` (`eventTypes = EventType "StepRecorded" :| [EventType "WorkflowCompleted", ...]`, `eventType = \case StepRecorded{} -> EventType "StepRecorded"; ...`), and change `decodeJournalEvent` to `EventType -> Value -> Either Text WorkflowJournalEvent`, dispatching on the tag's inner text instead of `o .: "kind"` (keep `"kind"` in `encodeJournalEvent` output unchanged). Import `EventType (..)` from `Kiroku.Store.Types`.
2. `keiro/test/Main.hs` — same mechanical treatment for `orderCodec`/`gappyCodec` (single event type: `decode = const parseOrderPlaced` works, or thread the tag for symmetry) and `counterCodec` (two event types: dispatch on the tag — `EventType "CounterAdded"` builds `CounterAdded <$> o .: "amount"`, `EventType "CounterAudited"` builds `CounterAudited ...`; delete the `"audited"`-sniffing). Update `decodeRaw` calls at `:375,379` to pass `EventType "OrderPlaced"`, and the `UnknownEventType` expectation at `:394` to `Left (UnknownEventType (EventType "OrderCancelled") [EventType "OrderPlaced"])`. Update the upcaster fixtures: `upcasters = [(1, const upcastOrderPlacedV1)]` and gappyCodec's `(3, Right)` becomes `(3, const Right)`.
3. The six jitsurei codecs in `jitsurei/src/Jitsurei/` — wrap tags in `EventType`, change each `parseFooEvent` to take the tag and dispatch on it (keep `"kind"` on encode), `const`-wrap any upcaster (only `OrderStream.hs` has one, `upcastOrderPlacedV1`). Update `jitsurei/test/Main.hs:42` to `decodeRaw orderCodec (EventType "OrderPlaced") 1 (...)` (import `EventType (..)`); `jitsurei/app/Main.hs` compiles unchanged (it only calls `decodeRecorded`).
4. `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` — `keiroJobCodec`: encode adds `"t" .= tagText` where `EventType tagText = Codec.eventType codec p`; `parseEnvelope` returns `(Maybe Text, Int, Value)` reading an optional `"t"`; decode resolves the tag per the Decision Log (header tag if present; sole member of `eventTypes` if the codec has exactly one; otherwise `Left` with message `"keiroJobCodec: payload has no event-type tag and codec has multiple event types"`), then calls `Codec.migrateToCurrent codec tag version dataValue` and `Codec.decode codec tag migrated`.
5. keiro-dsl codegen — in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`: `emitCodecValue` (line ~887) wraps tags (`eventTypesExpr` emits `EventType "Foo" :| [EventType "Bar", ...]`; the `eventType` arms emit `Foo {} -> EventType "Foo"`); the codec module's import block (line ~860) adds `import Kiroku.Store.Types (EventType (..))`; `upcastersExpr` (line ~924) emits `(n, const upcastFooVn)` so hand-owned hole signatures stay `Value -> Either Text Value`; `emitDecode` changes the generated parser to `parseFooEvent :: EventType -> Value -> Either Text FooEvent` dispatching on the tag (drop the `kind <- o .: "kind"` read; keep `"kind"` in `emitEncode` output). In `keiro-dsl/src/Keiro/Dsl/Harness.hs`: `upcastDecl` (line ~259) emits `decodeRaw fooCodec (EventType "FooEvent") n (...)` and the harness import block adds the `EventType` import. Run `cabal test keiro-dsl-test` and fix any substring assertions over scaffold output that mention the old codec text.
6. Generated fixtures — apply the same mechanical edits by hand to the nine checked-in `Codec.hs` files under `keiro-dsl/test/conformance{,-v2,-coldstart,-process,-process-runtime,-process-full}/Generated/` and to `keiro-dsl/test/conformance-v2/Generated/HospitalCapacity/Reservation/Harness.hs:42`, preserving each file's `@generated` header comment. (If you prefer regeneration: the `keiro-dsl` executable scaffolds from the `.keiro` specs in `keiro-dsl/test/fixtures/`, but hand-editing nine small files is the lower-risk documented path; the files must end up byte-stable under the determinism test in `keiro-dsl/test/Main.hs:232`. If you regenerate, diff against the hand-expected shape before committing.)

Finally add the regression test to the `describe "Keiro.Codec"` block in `keiro/test/Main.hs`: build a `RecordedEvent` via the existing `recordedFrom` helper with `eventType = EventType "CounterAudited"` and payload `object ["amount" Aeson..= (5 :: Int)]` (shape-compatible with `CounterAdded`, no discriminator), and assert `decodeRecorded counterCodec recorded == Right (CounterAudited 5)`. Before this milestone that exact input decoded as `CounterAdded 5` — state this in the test's name (e.g. `"decodes by the stored tag, not by payload shape (H1)"`).

Acceptance: `cabal build all --enable-tests` succeeds; `cabal test keiro-test`, `cabal test jitsurei-test`, `cabal test keiro-dsl-test`, and the six codec-bearing conformance suites (`cabal test keiro-dsl-conformance keiro-dsl-conformance-v2 keiro-dsl-conformance-coldstart keiro-dsl-conformance-process keiro-dsl-conformance-process-runtime keiro-dsl-conformance-process-full`) all pass; the new regression test is green.


### Milestone 2 — codec construction and migration hardening (M1, M2, M3, L1)

Scope: additive validation in `keiro-core/src/Keiro/Codec.hs`. At the end, a misconfigured codec is rejected at construction, future-versioned and malformed-stamp payloads fail with dedicated typed errors, and the truncated-chain error is honest.

Add `data CodecConfigError` and `mkCodec :: Codec e -> Either CodecConfigError (Codec e)` (constructors and exact validation rules in Interfaces below), export both, and document the raw `Codec` record literal as the unvalidated escape hatch (mirroring `mkEventStream`'s docs). Add `CodecError` constructors `VersionAhead !Int !Int` (stored version, codec version), `IncompleteUpcasterChain !Int !Int` (stuck-at version, target version), `MalformedSchemaVersionStamp !Value` (the offending metadata value), and `NonObjectCallerMetadata !Value`. In `migrateToCurrent`: the first guard becomes equality-only pass-through (`sourceVersion == schemaVersion -> Right payload`) with a preceding `sourceVersion > schemaVersion -> Left (VersionAhead ...)`; in `go`, the `nextChainStart ... Nothing` arm becomes `Left (IncompleteUpcasterChain version (codec ^. #schemaVersion))` (keep `UnknownVersion` for `sourceVersion < 1`). Change `extractSchemaVersion` to return `Either CodecError Int`: absent metadata or an object lacking the key yields `Right 1`; present non-object metadata, a non-numeric stamp, a non-integral number (e.g. `2.5`), or an out-of-`Int`-bounds number yields `Left (MalformedSchemaVersionStamp v)`. Change `metadataFor` to return `Either CodecError Value`, rejecting `Just` non-object input with `NonObjectCallerMetadata`; `encodeForAppendWithMetadata` and `decodeRecorded` propagate via `Either`'s monad.

Update the three external call sites in `keiro/test/Main.hs`: `:368` becomes `extractSchemaVersion (recordedFrom encoded) \`shouldBe\` Right 2`; the `metadataFor 2 Nothing` / `metadataFor 1 Nothing` fixture uses at `:389,529` unwrap the now-`Either` value (a tiny local helper `metadataForOrDie v = either (error . show) id (metadataFor v Nothing)`, or `shouldBeRight`).

Add tests to the `describe "Keiro.Codec"` block proving each behavior: `mkCodec` rejects `schemaVersion = 0` (`CodecSchemaVersionInvalid 0`), a duplicate rung (`upcasters = [(1, ...), (1, ...)]` at version 3 → `CodecDuplicateUpcasterSources [1]`), a gap (`[(1, ...)]` at version 3 → `CodecUpcasterChainIncomplete [2] 3`), and duplicate `eventTypes`; `mkCodec` accepts `counterCodec` and `orderCodec` unchanged. `decodeRaw orderCodec (EventType "OrderPlaced") 3 payload` (codec version 2) yields `Left (VersionAhead 3 2)`. A recorded event whose metadata is `Just (String "junk")` or whose stamp is `String "2"` fails with `MalformedSchemaVersionStamp`, while an event with *no* metadata still decodes as version 1 (assert with a v1 payload through `orderCodec`'s upcaster). `encodeForAppendWithMetadata codec (Just (String "x")) e` yields `Left (NonObjectCallerMetadata (String "x"))`. `decodeRaw gappyCodec (EventType "OrderPlaced") 1 ...` still reports `GapInUpcasterChain 2 3`, and a codec whose chain simply ends early now reports `IncompleteUpcasterChain` (e.g. version-4 codec with rungs `[(1,...),(2,...)]` decoding a v1 payload stalls at 3).

Acceptance: `cabal test keiro-test` green including the new cases; `cabal build all --enable-tests` still green (no other package calls the changed helpers — verified in the call-site inventory).


### Milestone 3 — stream and category constructor hygiene (H2, M7, M8, L8)

Scope: `keiro-core/src/Keiro/Stream.hs` plus its tests. At the end, the only ways to obtain a `StreamCategory` are `category`/`categoryUnsafe`, misuse failures point at the caller, and `entityStream` honors its own documentation.

Change the export list: export `StreamCategory` *without* `(..)` (this hides both the constructor and the `categoryTextOf` field selector — the selector alone would still permit record-update forgery), and export a new total accessor `categoryText :: StreamCategory a -> Text`. Add a `CategoryError` constructor `CategoryContainsIllegalChar !Char !Text` and extend `category` to reject any character satisfying `Data.Char.isSpace` or `Data.Char.isControl` (import `Data.Char qualified as Char`; check via `Text.find`). Do **not** reject `_`, `:`, or unicode letters — the camelCase/colon conventions are deliberately guidance-only per `docs/plans/66-...md`. Give `categoryUnsafe` a `HasCallStack` constraint (import `GHC.Stack (HasCallStack)`) and a descriptive error (`"Keiro.Stream.categoryUnsafe: invalid category " <> show t <> ": " <> show err`). Give `entityStream` and `entityStreamId` `HasCallStack` and make them `error` when `Text.null (Text.strip idSeg)` (message naming the category and the offending id), updating their Haddocks to state the guard; update the `StreamIdSegment` class doc to say renderings must be non-blank. Add a prominent Haddock warning to `stream` (`:40-41`): it bypasses all category validation and exists for low-level callers and tests; prefer `entityStream`.

Fix the tests in `keiro/test/Main.hs:335-346`: the `Right (Stream.StreamCategory "incident")` comparisons no longer compile; rewrite as `fmap Stream.categoryText (Stream.category "incident") \`shouldBe\` Right "incident"` (same for `"hospitalSurge"` and `"wf:fulfillment"` — these two assert the deliberate guidance-not-enforcement and must stay green). Add cases: `Stream.category "ord ers"` → `Left (Stream.CategoryContainsIllegalChar ' ' "ord ers")`; `Stream.category "ord\ners"` → illegal char; `Control.Exception.evaluate (Stream.entityStream cat "") \`shouldThrow\` anyErrorCall` and the same for `"   "` (hspec's `shouldThrow`/`anyErrorCall`; force with `evaluate . Stream.streamName` since the construction is lazy).

Acceptance: `cabal build all --enable-tests` (proves nothing else used the bare constructor) and `cabal test keiro-test` green.


### Milestone 4 — snapshot-policy coherence (M6, L2, L3)

Scope: `keiro-core/src/Keiro/EventStream.hs`, `keiro-core/src/Keiro/Snapshot/Policy.hs`, `keiro-core/src/Keiro/EventStream/Validate.hs`, and the three runtime call sites. At the end, an `EventStream` that asks for snapshots without a state codec is rejected by `mkEventStream`, `Every n` never fires at version 0, and `Custom` predicates can see terminality.

In `EventStream.hs`: add `data Terminality = Terminal | NotTerminal deriving stock (Eq, Show, Generic)` and export it; change `Custom`'s field to `!(Terminality -> state -> StreamVersion -> Bool)`; document on the `EventStream` record that `snapshotPolicy`/`stateCodec` must be set together and that `mkEventStream` enforces it. In `Snapshot/Policy.hs`: `shouldSnapshot :: SnapshotPolicy state -> Terminality -> state -> StreamVersion -> Bool`; the `Every` arm adds `version > 0 &&`; `OnTerminal` returns `terminality == Terminal`; `Custom decide` passes the terminality through. Update the three call sites: `keiro/src/Keiro/Command.hs:554-555` computes `terminality = if Keiki.isFinal ... then Terminal else NotTerminal`; `keiro/src/Keiro/Workflow.hs:442` passes `Terminal` (the completion marker), `:490` passes `NotTerminal` (a step append) — both literals become self-documenting, which is the point. In `EventStream/Validate.hs`: `mkEventStream` additionally emits an `EventStreamWarning` (reason text: `"snapshotPolicy is set but stateCodec is Nothing; snapshots would never be written"`) when the policy pattern-matches anything other than `Never` while `stateCodec` is `Nothing`, so such a stream is a `Left` at construction. (`SnapshotPolicy` has no `Eq` — match constructors.)

Tests in `keiro/test/Main.hs`: `shouldSnapshot (Every 2) NotTerminal () (StreamVersion 0)` is `False` while `(StreamVersion 2)` is `True`; a `Custom (\t _ _ -> t == Terminal)` policy fires exactly on `Terminal`; `mkEventStream "label" stream` with `snapshotPolicy = Every 10, stateCodec = Nothing` returns `Left` with the coherence warning (reuse the existing minimal `EventStream` fixture at `:403-408`, which today carries exactly the benign `Never`/`Nothing` pair — assert that one still passes). The existing snapshot integration tests (`:695-806`) exercise the `Every 2` + `Just defaultStateCodec` stream and must stay green unchanged.

Acceptance: `cabal test keiro-test` green (snapshot describe-blocks unchanged plus new unit cases); `cabal test jitsurei-test` green (jitsurei's `OrderStream.hs:56-57` snapshotting demo still works).


### Milestone 5 — integration-event wire fidelity (M4, M5)

Scope: `keiro-core/src/Keiro/Integration/Event.hs` and `keiro/src/Keiro/Inbox/Kafka.hs`. At the end, an integration event's `occurredAt` and `attributes` survive the Kafka hop, and a `content-type: application/json; charset=utf-8` payload decodes.

In `Integration/Event.hs`: add header names `headerOccurredAt = "keiro-occurred-at"` and `headerAttributes = "keiro-attributes"` (export both); `integrationHeaders` always emits `headerOccurredAt` (value `Text.pack (iso8601Show (event ^. #occurredAt))`, importing `Data.Time.Format.ISO8601 (iso8601Show)` — the `time` dependency is already in `keiro-core.cabal`) and emits `headerAttributes` only when `attributes` is `Just v` (value: `decodeUtf8` of `Lazy.toStrict (Aeson.encode v)` — compact JSON; import `Data.Text.Encoding`). Update the module and function Haddocks: after this change every envelope field crosses the hop (messageId, routing, schema info, source positions, causation/correlation, trace context, occurredAt, attributes, payload, key), so delete/replace the "consumers can read it from the payload" caveat. Fix `parseContentType`: normalize by stripping everything from the first `;` (`Text.takeWhile (/= ';')`), then strip+lowercase, before the `"application/json"` comparison; `OtherContentType` still preserves the *original* raw text. In `Inbox/Kafka.hs`: add `KafkaDecodeError` constructors `InvalidTimeHeader !Text !Text` and `InvalidJsonHeader !Text !Text`; parse `headerOccurredAt` when present via `iso8601ParseM` (falling back to `record ^. #receivedAt` when absent — in-flight messages from pre-M5 producers — and erroring on present-but-unparseable); parse `headerAttributes` when present via `Aeson.eitherDecodeStrict . encodeUtf8` (absent → `Nothing`); delete the apologetic comment at `:121-125`.

Tests in `keiro/test/Main.hs`: extend the existing Kafka round-trip test (`:2030-2056`) — set the record's `receivedAt` to a *different* instant than the envelope's `occurredAt` and assert `rebuilt ^. #occurredAt === envelope ^. #occurredAt` and `rebuilt ^. #attributes === envelope ^. #attributes` (give `sampleIntegrationEnvelope` a `Just` attributes value); add a fallback case (headers with `keiro-occurred-at` filtered out → `occurredAt == receivedAt`); add `parseContentType "application/json; charset=utf-8" \`shouldBe\` ApplicationJson` and `parseContentType "APPLICATION/JSON ; CHARSET=UTF-8" \`shouldBe\` ApplicationJson` next to the existing cases at `:2339-2343`; assert a malformed `keiro-occurred-at` yields `Left (InvalidTimeHeader ...)`. Check whether `sampleIntegrationEnvelope`'s `occurredAt`-based assertions elsewhere (e.g. the outbox publish tests around `:4028`) relied on the old substitute-receivedAt behavior and adjust.

Acceptance: `cabal test keiro-test` green; `cabal test jitsurei-test` green.


### Milestone 6 — full-repo verification and plan closure

Scope: no new behavior. Run the complete gate: `cabal build all --enable-tests`, then `cabal test keiro-test jitsurei-test keiro-dsl-test` and the six conformance suites from M1, then `just haskell-test` (adds the `jitsurei-diagrams --check` run). Re-read the Haddocks of every touched module for stale claims (in particular `Keiro.Codec`'s header narrative, `Keiro.Stream`'s construction story, `Keiro.Integration.Event`'s wire-mapping promises). Update this plan's Progress/Surprises/Outcomes sections, and tick the three `EP-2` rollup checkboxes in `docs/masterplans/9-keiro-production-readiness-hardening.md` (Progress section, lines beginning `- [ ] EP-2:`). Record the final shipped signatures in the Interfaces section below if anything drifted during implementation, with a Decision Log entry explaining the drift.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/keiro`. The repo uses GHC 9.12 via the nix devshell (`flake.nix`); if `cabal` is not on PATH, enter the devshell first (`nix develop`).

Baseline (Milestone 0):

```bash
cabal build all
cabal test keiro-test
```

Expected tail of the test run (counts will differ as tests are added):

```text
Finished in ... seconds
NNN examples, 0 failures
Test suite keiro-test: PASS
```

Per-milestone inner loop — after editing keiro-core, typecheck the contract package alone before chasing downstream errors:

```bash
cabal build keiro-core
```

Then let the compiler enumerate the breakage downstream (M1 only):

```bash
cabal build all --enable-tests 2>&1 | grep -E "^[^ ]+\.hs|error" | head -50
```

Work through errors package by package in the M1 order (keiro → jitsurei → keiro-pgmq → keiro-dsl src → keiro-dsl fixtures). The full suite battery:

```bash
cabal test keiro-test
cabal test jitsurei-test
cabal test keiro-dsl-test
cabal test keiro-dsl-conformance keiro-dsl-conformance-v2 keiro-dsl-conformance-coldstart
cabal test keiro-dsl-conformance-process keiro-dsl-conformance-process-runtime keiro-dsl-conformance-process-full
cabal test keiro-pgmq-test
```

Every suite ends with its `Test suite <name>: PASS` line. (`keiro-pgmq-test` installs the PGMQ extension into its ephemeral database via `pgmq-migration`; it needs the devshell's postgres with the pgmq extension available — if it fails for environmental reasons unrelated to your diff, verify it at least *builds*: `cabal build keiro-pgmq-test`.)

Repo gate (Milestone 6):

```bash
cabal build all --enable-tests
just haskell-test
```

`just haskell-test` runs `cabal test keiro-test`, `cabal test jitsurei-test`, and `cabal run jitsurei:exe:jitsurei-diagrams -- --check`; all three must pass.

Commit after each milestone using conventional commits, e.g.:

```text
feat(keiro-core)!: thread the event-type tag into Codec decode and upcasters

BREAKING CHANGE: Codec.decode is now EventType -> Value -> Either Text e;
eventTypes/eventType use kiroku's EventType; decodeRaw/migrateToCurrent
take the tag. decodeRecorded is unchanged.
```

(M2-M5 commits are non-breaking `feat(keiro-core):` / `fix(keiro-core):` commits; the keiro-dsl fixture updates can ride in the M1 commit or follow as `test(keiro-dsl):`.)


## Validation and Acceptance

Acceptance is behavioral, per milestone, and each new test fails before its fix and passes after:

1. Tag authority (H1): in `keiro/test/Main.hs`, a `RecordedEvent` tagged `CounterAudited` whose payload is `{"amount":5}` (no discriminator) decodes to `Right (CounterAudited 5)`. On the pre-M1 tree the same input decodes to `Right (CounterAdded 5)` — you can demonstrate the before-state by running the new test against a stash of the old `counterCodec` if an auditor asks, but the committed suite simply asserts the new behavior.
2. Construction-time validation (M1 finding): `mkCodec` on a version-3 codec with upcasters `[(1, f)]` returns `Left (CodecUpcasterChainIncomplete [2] 3)`; on `counterCodec` it returns `Right`. A version-0 codec is rejected at construction, not at first encode.
3. Version skew honesty (M2/M3/L1): `decodeRaw` of a version-3-stamped payload through a version-2 codec is `Left (VersionAhead 3 2)`; a stamp of `"2"` (string) is `Left (MalformedSchemaVersionStamp ...)`; an event with no metadata at all still decodes as version 1 through the upcaster chain; a truncated chain reports `IncompleteUpcasterChain`, not `UnknownVersion`.
4. Category hygiene (H2/M7/M8/L8): `Stream.category "ord ers"` is `Left (CategoryContainsIllegalChar ' ' "ord ers")`; `Stream.category "wf:fulfillment"` and `"hospitalSurge"` remain `Right`; `StreamCategory "$all"` no longer compiles anywhere in the repo (proven by `cabal build all --enable-tests`); forcing `entityStream cat ""` throws an `ErrorCall` whose message names the call site (HasCallStack).
5. Snapshot coherence (M6/L2/L3): `mkEventStream` on an `Every 10`/`Nothing` stream returns `Left` with the coherence warning; `shouldSnapshot (Every 2) NotTerminal s (StreamVersion 0)` is `False`; a `Custom` predicate observes `Terminal` on the completion path. Existing snapshot integration tests (write-at-threshold, tail-hydration, corrupt-JSON fallback at `keiro/test/Main.hs:695-806`) pass unchanged.
6. Wire fidelity (M4/M5): the Kafka round-trip test reconstructs `occurredAt` and `attributes` from headers when `receivedAt` differs; with the `keiro-occurred-at` header removed, `occurredAt` falls back to `receivedAt`; `parseContentType "application/json; charset=utf-8"` is `ApplicationJson` and a charset-bearing envelope decodes through `decodeJsonIntegrationEvent`.
7. Whole-repo: `cabal build all --enable-tests` and the full suite battery in Concrete Steps pass; `just haskell-test` passes.

Beyond compilation, the end-to-end demonstration is the jitsurei suite: `cabal test jitsurei-test` exercises real append/decode cycles against PostgreSQL through the changed codecs (including the v1-upcast test at `jitsurei/test/Main.hs:42` now passing the tag), proving the contract changes work against a live store, not just unit fixtures.


## Idempotence and Recovery

Every step is a source edit plus a build/test cycle — re-running any command is safe and produces the same result. The only non-reentrant stretch is Milestone 1's middle (after the keiro-core signature change, before all call sites are fixed) when `cabal build all` fails by design; recovery is always "keep fixing the next compile error" or `git checkout -- <path>` to retreat to the last commit. Commit at each milestone boundary so any milestone can be reverted independently; M2-M5 are mutually independent and individually revertible. No migrations, no destructive operations, no generated artifacts other than the nine hand-maintained dsl fixtures (which are plain checked-in files; if an attempted regeneration via the `keiro-dsl` CLI produces unexpected diffs, discard with `git checkout -- keiro-dsl/test` and hand-edit instead). If `keiro-pgmq-test` is environmentally unavailable, fall back to `cabal build keiro-pgmq-test` and note it in Progress.


## Interfaces and Dependencies

No new library dependencies anywhere: `keiro-core` already depends on `aeson`, `text`, `time`, `scientific`, `kiroku-store`, `lens`/`generic-lens` (see `keiro-core/keiro-core.cabal`); the new imports (`Data.Char`, `GHC.Stack`, `Data.Time.Format.ISO8601`, `Data.Text.Encoding`) are all within those packages or `base`.

The contract this plan publishes — sibling plans (notably `docs/plans/69-...md` for `keiro/src/Keiro/Command.hs` and `docs/plans/74-...md` for keiro-pgmq) build against exactly these final shapes in `keiro-core/src/Keiro/Codec.hs`:

```haskell
-- Keiro.Codec (keiro-core/src/Keiro/Codec.hs)
type Upcaster = (Int, EventType -> Value -> Either Text Value)

data Codec e = Codec
    { eventTypes :: !(NonEmpty EventType)
    , eventType :: !(e -> EventType)
    , schemaVersion :: !Int
    , encode :: !(e -> Value)
    , decode :: !(EventType -> Value -> Either Text e)
    , upcasters :: ![Upcaster]
    }

data CodecError
    = UnknownEventType !EventType ![EventType]
    | InvalidSchemaVersion !Int
    | UnknownVersion !Int                     -- stored version < 1
    | VersionAhead !Int !Int                  -- stored version, codec version (M2)
    | UpcasterError !Int !Text
    | DecodeFailed !Text
    | GapInUpcasterChain !Int !Int
    | IncompleteUpcasterChain !Int !Int       -- stuck-at version, target version (L1)
    | MalformedSchemaVersionStamp !Value      -- M3
    | NonObjectCallerMetadata !Value          -- M3

data CodecConfigError
    = CodecSchemaVersionInvalid !Int          -- schemaVersion < 1
    | CodecDuplicateEventTypes ![EventType]
    | CodecDuplicateUpcasterSources ![Int]
    | CodecUpcasterSourceOutOfRange !Int !Int -- source, schemaVersion
    | CodecUpcasterChainIncomplete ![Int] !Int -- missing sources, schemaVersion

mkCodec :: Codec e -> Either CodecConfigError (Codec e)
-- valid iff: schemaVersion >= 1; eventTypes pairwise distinct;
-- upcaster sources, sorted, are exactly [1 .. schemaVersion - 1].

encodeForAppend             :: Codec e -> e -> Either CodecError EventData              -- unchanged
encodeForAppendWithMetadata :: Codec e -> Maybe Value -> e -> Either CodecError EventData -- unchanged type, now rejects non-object metadata
decodeRecorded   :: Codec e -> RecordedEvent -> Either CodecError e                     -- unchanged
decodeRaw        :: Codec e -> EventType -> Int -> Value -> Either CodecError e         -- + tag, + membership check
migrateToCurrent :: Codec e -> EventType -> Int -> Value -> Either CodecError Value     -- + tag, + VersionAhead
extractSchemaVersion :: RecordedEvent -> Either CodecError Int                          -- was: -> Int
metadataFor          :: Int -> Maybe Value -> Either CodecError Value                   -- was: -> Value
```

```haskell
-- Keiro.Stream (keiro-core/src/Keiro/Stream.hs)
-- exports: Stream (..), stream, streamName, mapStreamName,
--          StreamCategory,            -- constructor and field NOT exported (H2)
--          categoryText, CategoryError (..), category, categoryUnsafe, categoryName,
--          StreamIdSegment (..), entityStream, entityStreamId
categoryText   :: StreamCategory a -> Text
category       :: Text -> Either CategoryError (StreamCategory a)
categoryUnsafe :: (HasCallStack) => Text -> StreamCategory a
entityStream   :: (HasCallStack) => StreamCategory a -> Text -> Stream a   -- errors on blank id
entityStreamId :: (HasCallStack, StreamIdSegment i) => StreamCategory a -> i -> Stream a

data CategoryError
    = CategoryEmpty
    | CategoryContainsSeparator !Text
    | CategoryReserved !Text
    | CategoryContainsIllegalChar !Char !Text  -- L8: whitespace/control only
```

```haskell
-- Keiro.EventStream (keiro-core/src/Keiro/EventStream.hs)
data Terminality = Terminal | NotTerminal     -- exported; Eq, Show, Generic

data SnapshotPolicy state
    = Never
    | Every !Int
    | OnTerminal
    | Custom !(Terminality -> state -> StreamVersion -> Bool)  -- L3: sees terminality

-- Keiro.Snapshot.Policy (keiro-core/src/Keiro/Snapshot/Policy.hs)
shouldSnapshot :: SnapshotPolicy state -> Terminality -> state -> StreamVersion -> Bool
-- Every n fires only when version > 0 AND version `mod` n == 0 (L2)

-- Keiro.EventStream.Validate (keiro-core/src/Keiro/EventStream/Validate.hs)
mkEventStream :: ... -> Either [EventStreamWarning] (EventStream ...)  -- signature unchanged;
-- additionally rejects snapshotPolicy /= Never with stateCodec = Nothing (M6)
```

```haskell
-- Keiro.Integration.Event (keiro-core/src/Keiro/Integration/Event.hs)
headerOccurredAt, headerAttributes :: Text   -- "keiro-occurred-at" (RFC3339), "keiro-attributes" (compact JSON)
-- integrationHeaders always emits keiro-occurred-at; keiro-attributes only when attributes is Just.
-- parseContentType strips media-type parameters (";" onward) before comparison (M5).

-- Keiro.Inbox.Kafka (keiro/src/Keiro/Inbox/Kafka.hs)
data KafkaDecodeError
    = MissingHeader !Text
    | InvalidIntHeader !Text !Text
    | InvalidUuidHeader !Text !Text
    | InvalidTimeHeader !Text !Text   -- M4
    | InvalidJsonHeader !Text !Text   -- M4
-- occurredAt: parsed from keiro-occurred-at when present, else receivedAt (compat fallback);
-- attributes: parsed from keiro-attributes when present, else Nothing.
```

`StateCodec` (`keiro-core/src/Keiro/EventStream.hs:91-97`) is deliberately untouched: snapshots are single-shape per stream, there is no tag to thread, and `keiro/src/Keiro/Snapshot/Codec.hs` (`defaultStateCodec`) compiles unchanged. The keiro-pgmq `JobCodec` type is also unchanged; only `keiroJobCodec`'s internals and envelope (`{"v", "t", "data"}`) move.
