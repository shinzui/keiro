---
id: 25
slug: opentelemetry-semantic-conventions-audit-and-instrumentation-alignment
title: "OpenTelemetry semantic-conventions audit and instrumentation alignment"
kind: exec-plan
created_at: 2026-05-19T22:10:07Z
intention: "intention_01ks14d0rfeg9teej0zc4jfmta"
---

# OpenTelemetry semantic-conventions audit and instrumentation alignment

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This work audits every place in the `keiro` library where the code already touches
tracing — outbox publishing, inbox consumption, the integration-event envelope —
and either adds the missing OpenTelemetry instrumentation or fixes existing
instrumentation so it complies with the **OpenTelemetry semantic conventions**.

The semantic conventions are a published cross-language specification that tells
instrumentation authors what to *call* their spans, what *kind* (`Producer`,
`Consumer`, `Client`, `Server`, `Internal`) the span should have, and what
attribute keys to attach (for example, `messaging.system`, `messaging.operation.type`,
`messaging.destination.name`, `db.system.name`, `error.type`). When two libraries
follow the same conventions, a single dashboard or query in Grafana, Honeycomb,
Datadog, etc. works against both. When they don't, traces are noisy at best and
unusable for cross-service analysis at worst.

The Haskell binding to the spec — and the source of truth this plan audits against —
is the package **`hs-opentelemetry-semantic-conventions`**, generated from the
upstream YAML model and exposed as one module: `OpenTelemetry.SemanticConventions`.
It defines around 400 typed `AttributeKey` values such as `messaging_system ::
AttributeKey Text` and `messaging_operation_type :: AttributeKey Text`, each wrapping
the canonical dotted spec name (`"messaging.system"`, `"messaging.operation.type"`)
and Haddocked with its requirement level (`required` / `conditionally required` /
`recommended` / `opt-in`). The package lives on disk at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/`;
its generated source is
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`
(29,049 lines, `v1.40` of the spec).

**What's there today.** `keiro` already carries the *data shape* of
distributed-tracing context: the `TraceContext` record in
`src/Keiro/Integration/Event.hs` (lines 140–144), its `traceparent` / `tracestate`
storage columns in `src/Keiro/Outbox/Schema.hs:69–71` and
`src/Keiro/Inbox/Schema.hs:69–70`, and the Kafka header round-trip through
`headerTraceParent`/`headerTraceState` (defined at
`src/Keiro/Integration/Event.hs:227–229`, threaded through
`integrationHeaders` and `integrationEventFromKafka`). But it does **not**:

* declare any dependency on `hs-opentelemetry-api`,
  `hs-opentelemetry-semantic-conventions`, or any propagator;
* create spans anywhere — there are zero `inSpan` / `withSpan` call sites in
  `src/`;
* call the standard W3C propagator to *construct* a `traceparent` value (it is
  treated as opaque `Text` that some upstream caller is expected to provide);
* set any messaging attributes on a span (because no span exists).

So the audit is two-sided:

1. **Conformance audit (read-only).** Identify every site where instrumentation
   should exist according to the messaging, database, and error conventions, list
   the exact `AttributeKey`s that apply, and write the findings into a checked-in
   audit document. This is the part a reader can verify by reading the document
   and grepping the source.
2. **Instrumentation alignment (additive code).** Add an opt-in tracing surface
   to the library: a small `Keiro.Telemetry` module that provides the
   `MonadTracer`-friendly span helpers, depends on `hs-opentelemetry-api` and
   `hs-opentelemetry-semantic-conventions`, and is *called* from the outbox
   publisher, inbox consumer, command runner, and read-model rebuild paths. The
   tracer instance is supplied by the application; when no tracer is supplied
   the calls degrade to a no-op via `hs-opentelemetry-api`'s noop tracer
   provider, so existing applications that do not configure OTel are unaffected.

**What a reader can do after this change that they could not do before:**

* Read `docs/research/opentelemetry-semconv-audit.md` and see, in one place, the
  list of every span we *should* emit, the required and recommended attributes
  per span, and the citation back to the relevant Haddock section in
  `OpenTelemetry.SemanticConventions`.
* Wire an SDK-backed `Tracer` into a `jitsurei`-style application, run the
  guide-backed Kafka demo, and see, on the console exporter:
  - one `Producer`-kind span per published outbox row, named
    `"send <destination-topic>"`, carrying `messaging.system = "kafka"`,
    `messaging.operation.type = "publish"`, `messaging.operation.name = "send"`,
    `messaging.destination.name = <topic>`, `messaging.message.id = <messageId>`,
    `messaging.kafka.message.key = <key>` (when present), and `error.type` on
    failure;
  - one `Consumer`-kind span per inbox row, named `"process <topic>"`, with the
    same conventions plus `messaging.kafka.offset` and
    `messaging.destination.partition.id`;
  - the W3C `traceparent` and `tracestate` headers populated from the *current
    span context* via the standard W3C propagator rather than from an
    application-supplied string, and successfully linking producer → consumer
    spans across two `keiro` processes.
* Run `cabal test keiro-test` and see new assertions covering the
  `Keiro.Telemetry` helpers: attribute keys round-trip to the exact spec names,
  the noop tracer produces no observable side effect, and the in-memory
  exporter captures the expected span tree for a fake produce/consume round
  trip.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] **Milestone 1: Conformance audit document.** Wrote
      `docs/research/opentelemetry-semconv-audit.md` (473 lines, 2026-05-19).
      One section per instrumentation site identified in §Context and
      Orientation. Citations to `OpenTelemetry.SemanticConventions` were
      verified by `grep` against the on-disk module — see "Verifying the
      citations" section in the audit. Hydration, snapshot, read-model
      rebuild, projection, and timer sites are documented but explicitly
      deferred to a follow-up pass behind the M6 command span; see
      "Follow-ups out of scope" in the audit and the corresponding Decision
      Log entry.
- [x] **Milestone 2: Add the tracing dependencies (2026-05-19).** Added
      `hs-opentelemetry-api >= 0.3 && < 0.4`,
      `hs-opentelemetry-semantic-conventions >= 0.1 && < 1`, and
      `unliftio-core >= 0.2` as `keiro` library `build-depends` in
      `keiro.cabal`. Added `hs-opentelemetry-sdk >= 0.1 && < 0.2`,
      `hs-opentelemetry-exporter-in-memory >= 0.0.1 && < 0.1`, and
      `hs-opentelemetry-propagator-w3c >= 0.1 && < 0.2` (plus
      `hs-opentelemetry-api` and `unliftio-core`) to the `keiro-test` stanza.
      `cabal build all` exits 0 (verified 2026-05-19). Bounds diverge from
      the plan's original draft because the on-disk v1.40 packages don't
      resolve as a coherent set — see Surprises & Discoveries and the
      corresponding Decision Log entries for the full rationale.
- [x] **Milestone 3: Introduce `Keiro.Telemetry` (2026-05-19).** New module
      at `src/Keiro/Telemetry.hs` exposes `withProducerSpan`,
      `withConsumerSpan`, `withCommandSpan`, `traceContextFromCurrentSpan`,
      `traceContextFromHeaders`, and `injectTraceContext`, plus 13 vendored
      `AttributeKey` bindings for keys absent from Hackage's
      `hs-opentelemetry-semantic-conventions 0.1.0.0`. Tests added in
      `test/Main.hs` under `describe "Keiro.Telemetry"`. All 6 examples
      green (verified 2026-05-19); full suite is 71 examples / 0 failures,
      no regression. The tests cover the three properties the plan
      prescribed: (a) the noop-tracer (`Nothing`) path calls the body
      exactly once and returns its value; (b) every vendored
      `AttributeKey`'s textual payload matches the spec dotted-name; (c)
      `traceContextFromHeaders` extracts a non-empty `TraceContext` from a
      sample W3C `traceparent` header pair (and returns `Nothing` when the
      header is absent).
- [x] **Milestone 4: Instrument `Keiro.Outbox` and `Keiro.Outbox.Kafka`
      (2026-05-19).** `OutboxPublishOptions` gains `tracer :: !(Maybe
      Tracer)` (defaults to `Nothing` via `defaultPublishOptions`).
      `publishClaimedOutbox` now wraps each row's publish call in
      `withProducerSpan` with attributes from `outboxRowToKafkaRecord` and
      the envelope; on `PublishFailed` the helper sets
      `error.type = "publish_failed"` and span status `Error errMsg`.
      `Eq` and `Show` were dropped from `OutboxPublishOptions` because
      `Tracer` carries neither — no callers required either instance.
      New in-memory-exporter test `publishClaimedOutbox emits a Producer
      span with messaging semconv attributes` exercises the happy and
      failure paths against a real ephemeral Postgres store and asserts
      span name, kind, attributes, and status. Suite: 72 examples / 0
      failures.
- [ ] **Milestone 5: Instrument `Keiro.Inbox` and `Keiro.Inbox.Kafka`.** Wrap
      the receive path in `Keiro.Telemetry.withConsumerSpan`, extracting any
      upstream `traceparent` from the Kafka headers via the W3C propagator
      *before* opening the span so the consumer span is a child of the producer
      span. Set `messaging.kafka.offset`, `messaging.kafka.consumer.group`
      (from the new `groupId` field on the inbox config), and
      `messaging.destination.partition.id`. In-memory-exporter test asserts the
      producer→consumer parent/child relationship is preserved through Kafka
      headers.
- [ ] **Milestone 6: Instrument `Keiro.Command`.** Open one `Internal` span
      per `runCommand` / `runCommandWithSql` / `runCommandWithSqlEvents`
      invocation, named after the resolved stream name, with attributes
      describing the stream identity, retry attempt, and (on the database
      sub-span) the appended event count. The span surface is unconditional —
      a noop tracer makes it free — so callers do not need to opt in.
- [ ] **Milestone 7: Wire up the W3C propagator in `Keiro.Integration.Event`.**
      Add `traceContextFromCurrentSpan` / `traceContextFromHeaders` helpers in
      `Keiro.Telemetry` that bridge between the `TraceContext` record and the
      `Propagator` API. Replace any caller that constructs a `TraceContext`
      from a string with one that goes through the propagator. Update
      `jitsurei/app/Main.hs:116` (currently `traceContext = Nothing`) to a
      worked example that captures the current span context.
- [ ] **Milestone 8: Guide-backed example and `docs/guides`.** Add a new
      guide-backed walk-through under `docs/guides/telemetry/README.md` showing
      a producer → consumer trace end to end with the console exporter, and a
      matching `jitsurei` example so `cabal test jitsurei-test` exercises it.
- [ ] **Milestone 9: Final sweep.** Re-read `docs/research/opentelemetry-semconv-audit.md`
      against the post-implementation `src/` and reconcile every "gap" entry
      either as "closed" or as a deliberate "out of scope, see §Decision Log".
      Update Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Discovery (2026-05-19): The on-disk `hs-opentelemetry` packages do not
  resolve as a coherent set.** `hs-opentelemetry-api` is at 1.40-era 0.4.0.0
  on disk, but the local `hs-opentelemetry-sdk` / `hs-opentelemetry-exporter-in-memory`
  / `hs-opentelemetry-propagator-w3c` all pin `hs-opentelemetry-api ==0.3.*`,
  and the local `shibuya-core 0.5.0.0` does the same — and breaks at compile
  time against the 0.4 API surface (`Ctx.detachContext` signature change in
  `src/Shibuya/Telemetry/Effect.hs:285`). Conclusion: the local on-disk tree
  is mid-upgrade. **Action taken:** dropped every `hs-opentelemetry-*`
  `packages:` entry from `cabal.project` so the resolver picks the Hackage
  0.3-series release (`hs-opentelemetry-api 0.3.1.0`,
  `hs-opentelemetry-semantic-conventions 0.1.0.0`,
  `hs-opentelemetry-sdk 0.1.0.1`,
  `hs-opentelemetry-exporter-in-memory 0.0.1.5`,
  `hs-opentelemetry-propagator-w3c 0.1.0.0`). Bounds in
  `keiro.cabal` adjusted accordingly. Build is green: `cabal build all`
  exits 0 (verified 2026-05-19).
- **Discovery (2026-05-19): Hackage `hs-opentelemetry-semantic-conventions
  0.1.0.0` only carries 9 of the 22+ typed `AttributeKey`s the audit
  cites.** Verified by `grep` against the unpacked Hackage source: present
  are `otel_statusCode`, `otel_statusDescription`, `error_type`,
  `messaging_system`, `messaging_destination_name`, `messaging_message_id`,
  `messaging_batch_messageCount`, `messaging_kafka_message_key`,
  `messaging_kafka_message_tombstone`; absent are
  `messaging_operation_type`, `messaging_operation_name`,
  `messaging_destination_partition_id`, `messaging_kafka_offset`,
  `messaging_consumer_group_name`, `messaging_client_id`, and every
  `db_*` key. The on-disk v1.40 module has all of them, but as noted
  above we cannot link against it. **Action taken:** the audit citations
  remain pinned to the on-disk v1.40 module (which is the canonical
  upstream spec). `Keiro.Telemetry` (M3) will *vendor* the missing typed
  bindings as locally-defined `AttributeKey`s pointing at the same
  dotted-name strings, so the wire-level attribute keys match the spec
  exactly. When `hs-opentelemetry` ships a Hackage release that pairs the
  post-0.3 API with the v1.40 semantic-conventions, the vendored bindings
  can be replaced with `import OpenTelemetry.SemanticConventions
  (messaging_operation_type, …)`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Audit and instrumentation land in the same plan rather than as two
  separate ExecPlans.
  Rationale: the audit document is only meaningful as a checklist for the code
  change; producing it on its own would create a static document that drifts the
  moment the next refactor lands. Bundling the two means the audit and the
  source agree at the moment of merge, and the audit becomes the spec the
  instrumentation tests check.
  Date: 2026-05-19

- Decision: `Keiro.Telemetry` is a *thin* wrapper over `hs-opentelemetry-api`
  rather than its own effect.
  Rationale: `hs-opentelemetry-api` already exposes `MonadTracer` and `inSpan`,
  and `effectful`'s `Reader` effect provides the `MonadTracer` instance per the
  upstream `OpenTelemetry-Effectful-Guide.md`. Building a bespoke `Telemetry`
  effect on top of that is duplication. The wrapper exists only to (a) bind
  the `OpenTelemetry.SemanticConventions` keys to ergonomic helpers like
  `withProducerSpan`, (b) provide a `noopTracer` fallback so the library
  remains zero-config, and (c) keep the propagator wiring in one place.
  Date: 2026-05-19

- Decision: Use `messaging.operation.type = "publish"` (spec value) rather than
  the legacy `messaging.operation = "send"` (deprecated attribute
  `messaging_operation` still exported by the generated module at line 3416).
  Rationale: the upstream spec retired `messaging.operation` in favor of
  `messaging.operation.type` and `messaging.operation.name`. The Haskell module
  keeps the old key under `-- $registry_messaging_deprecated` (line 3413) only
  for backwards compatibility. New instrumentation should use the current
  attribute names.
  Date: 2026-05-19

- Decision: Span name for outbox publish is `"send <destination>"` and for
  inbox process is `"process <destination>"`, matching the convention in
  `hs-opentelemetry-instrumentation-hw-kafka-client` (see
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-hw-kafka-client-Instrumentation-Guide.md`).
  Rationale: keiro's outbox publishes via a caller-supplied `publish` function
  rather than calling `produceMessage` directly, so we cannot reuse the kafka
  instrumentation package wholesale. Mirroring its span-name convention keeps
  downstream dashboards consistent whether the consumer is using
  `hs-opentelemetry-instrumentation-hw-kafka-client` directly or the keiro
  outbox.
  Date: 2026-05-19

- Decision: The audit document scopes the instrumentation milestones (M4–M7)
  to the messaging boundary (outbox publish, inbox consume) and the command
  runner (M6). Hydration, snapshot, read-model rebuild, projection apply,
  and timer fire are catalogued but deferred to a follow-up pass.
  Rationale: the command span opened in Milestone 6 already attributes the
  wall-clock time these helpers consume, so per-step child spans are
  cosmetic until profiling demands them. Keeping the patch small reduces the
  surface area of the first OpenTelemetry adoption in keiro and isolates
  any rough edges to the higher-value sites.
  Date: 2026-05-19

- Decision: Use Hackage releases of every `hs-opentelemetry-*` package
  instead of the on-disk v1.40 sources under
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`.
  Rationale: see Surprises & Discoveries entry. Local sources are mid-upgrade
  and pulling them in transitively breaks `shibuya-core 0.5.0.0`. The
  Hackage 0.3-series surface is what every keiro-facing dependency
  (`shibuya-core`, `message-db-hs`, `kiroku-otel`) already compiles against.
  **Bound revisions (vs. plan's original):**
  `hs-opentelemetry-api >= 0.3 && < 0.4` (was `^>= 0.2`),
  `hs-opentelemetry-semantic-conventions >= 0.1 && < 1` (was `^>= 0.1`),
  `hs-opentelemetry-exporter-in-memory >= 0.0.1 && < 0.1` (was `^>= 0.1`),
  `hs-opentelemetry-sdk >= 0.1 && < 0.2` (was `^>= 0.1`),
  `hs-opentelemetry-propagator-w3c >= 0.1 && < 0.2` (was `^>= 0.1`).
  Date: 2026-05-19

- Decision: Where the Hackage v0.1.0.0 `hs-opentelemetry-semantic-conventions`
  release omits a typed `AttributeKey` named by the spec (and present in
  the on-disk v1.40 module), `Keiro.Telemetry` vendors a local
  `AttributeKey` whose `Text` payload is the dotted-name string from the
  spec.
  Rationale: the wire-level attribute key is what dashboards key on; the
  Haskell binding's typed shape is convenience. Vendoring keeps the
  per-span attribute set spec-conformant today and avoids waiting for an
  upstream release. Replacement with the upstream symbol is a single-import
  swap once a compatible release lands. The vendored keys are listed in
  `src/Keiro/Telemetry.hs` with a `-- TODO: replace with upstream import
  once available` comment.
  Date: 2026-05-19

- Decision: `Keiro.Telemetry`'s span helpers take an explicit `Maybe Tracer`
  parameter instead of a `MonadTracer` typeclass constraint (as the plan
  draft originally proposed).
  Rationale: keiro internals run inside `Eff es` with `IOE :> es` from
  `effectful`. Demanding `MonadTracer` on those signatures would force the
  library to introduce a `Reader Tracer` effect throughout the publisher /
  consumer / command surfaces — invasive for what is a thin auxiliary
  surface, and inconsistent with the "tracer lives on
  `OutboxPublishOptions`" pattern the plan already calls for in Milestone
  4. Passing `Maybe Tracer` keeps the helpers stand-alone: under `Nothing`
  they degrade to a one-branch pass-through; under `Just t` they invoke
  `OpenTelemetry.Trace.Core.inSpan'`, which itself takes the `Tracer`
  explicitly. The plan's Interfaces and Dependencies section is now
  out-of-date on this point; the audit document and milestone bodies
  reflect the final shape.
  Date: 2026-05-19

- Decision: `Keiro.Telemetry`'s tests live inside the existing
  `test/Main.hs` under a new `describe "Keiro.Telemetry"` block, not as a
  separate `test/Keiro/TelemetrySpec.hs` file (as the plan originally
  proposed).
  Rationale: the project's test layout is a single `Main.hs` with all
  `describe` blocks colocated. Splitting one module out would introduce a
  different layout for new code; matching the existing pattern keeps the
  test bookkeeping uniform. The suite now reports 71 examples / 0 failures.
  Date: 2026-05-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`keiro` is a Haskell library for event sourcing and workflow orchestration. The
source lives under `src/Keiro/`. The library is built with `cabal` and tested
with `hspec`. Build commands are run from the repository root
`/Users/shinzui/Keikaku/bokuno/keiro/`.

### Trace context as it exists today

Three modules already speak the *vocabulary* of distributed tracing, but only
in terms of opaque `traceparent`/`tracestate` strings:

* **`src/Keiro/Integration/Event.hs`** defines the public integration-event
  envelope. Lines 140–144 declare:

  ```haskell
  data TraceContext = TraceContext
    { traceparent :: !Text
    , tracestate :: !(Maybe Text)
    }
    deriving stock (Eq, Show, Generic)
  ```

  Lines 196–200 emit those values as `traceparent` and `tracestate` Kafka
  headers when the envelope is serialized. The names are defined as the
  literal lowercase strings at lines 227–229 — they match the W3C TraceContext
  HTTP header names, which is the convention the OTel W3C propagator uses on
  Kafka headers too.

* **`src/Keiro/Outbox/Schema.hs`** stores the same two strings on every
  enqueued outbox row (`traceparent TEXT, tracestate TEXT` columns at lines
  69–71) and round-trips them through the `keiro_outbox` table. The
  `OutboxRow` type at line 484 includes the same two `Maybe Text` fields.

* **`src/Keiro/Inbox/Schema.hs`** mirrors the storage on the consumer side
  (columns at lines 68–70, `InboxRow` at line 414).

* **`src/Keiro/Inbox/Kafka.hs:104–106`** decodes them out of the inbound Kafka
  header list:

  ```haskell
  let traceContext = case Prelude.lookup headerTraceParent hs of
        Nothing -> Nothing
        Just tp -> Just (TraceContext tp (Prelude.lookup headerTraceState hs))
  ```

What is missing: nothing in the library ever *constructs* a `traceparent` from
a real span, never *extracts* a span context from one for parenting, and never
opens a span around any operation. The `traceparent` is purely opaque
metadata that an upstream HTTP handler is expected to have set. There is also
no dependency on `hs-opentelemetry-api` in `keiro.cabal` (lines 61–84) — the
library is currently OpenTelemetry-shaped but OpenTelemetry-free.

### The instrumentation sites we will audit

These are the call sites the audit document (Milestone 1) will catalogue. For
each, the audit needs the span name, span kind, the OTel attribute keys, and
the citation back to the `OpenTelemetry.SemanticConventions` Haddock section.

* **Outbox enqueue** — `enqueueOutboxTx`, `enqueueIntegrationEventTx`,
  `enqueueProducerEventTx` in `src/Keiro/Outbox.hs`. These run inside a hasql
  `Tx.Transaction`. Span kind: `Internal` (the enqueue is an in-process write,
  not a publish over the network). Attributes: messaging conventions
  (`messaging.system`, `messaging.operation.type = "create"`,
  `messaging.destination.name`, `messaging.message.id`).
* **Outbox publish** — `publishClaimedOutbox` in `src/Keiro/Outbox.hs:228`
  and `outboxRowToKafkaRecord` in `src/Keiro/Outbox/Kafka.hs:55`. Span kind:
  `Producer`. This is the main producer-side span.
* **Inbox consume** — `integrationEventFromKafka` in
  `src/Keiro/Inbox/Kafka.hs:86`. Span kind: `Consumer`, named
  `"process <topic>"`.
* **Inbox process** — the user handler that runs after the integration event
  is decoded; covered by the integration-event consumer span and any
  downstream `Internal` spans the user opens.
* **Command run** — `runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`
  in `src/Keiro/Command.hs:250–339`. Span kind: `Internal`. Attributes: stream
  name, retry attempt count, `db.system.name = "postgresql"` on the
  hasql-transaction sub-span.
* **Hydration** — `hydrate`, `hydrateFull` in `src/Keiro/Command.hs:96–248`.
  Span kind: `Internal`, child of the command span. Attributes: page size,
  events replayed.
* **Snapshot read/write** — `hydrateWithSnapshot`, `writeSnapshot` in
  `src/Keiro/Snapshot.hs`. Span kind: `Internal` (under the command span).
* **Read-model rebuild** — `src/Keiro/ReadModel/Rebuild.hs`. Span kind:
  `Internal`. One span per rebuild invocation; `db.collection.name` for the
  read-model table.
* **Projection apply** — `src/Keiro/Projection.hs`. Span kind: `Internal`.
* **Timer fire** — `src/Keiro/Timer.hs`. Span kind: `Internal`.

The audit document does *not* try to instrument the underlying hasql calls
themselves — that is `hasql-opentelemetry`'s job (the project at
`/Users/shinzui/Keikaku/bokuno/hasql-opentelemetry`, registered in mori but
not currently a `keiro` dependency). We will note its existence as a
follow-up.

### The OpenTelemetry semantic conventions surface we audit against

The single source of truth on disk is

```text
/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Three section anchors carry the bulk of what `keiro` needs:

* **Messaging spans** — `-- $messaging_attributes` at line 27047. This is the
  full set of attributes used in messaging systems. Mandatory (required):
  `messaging.system`. Recommended: `messaging.client.id`,
  `messaging.destination.partition.id`. Conditionally required:
  `messaging.destination.template`, `messaging.destination.temporary`,
  `messaging.destination.anonymous`, `messaging.consumer.group.name`,
  `messaging.destination.subscription.name`, and `messaging.batch.message_count`
  when the span describes a batch.
* **Kafka-specific messaging** — `-- $messaging_kafka` at line 27197 and
  `-- $registry_messaging_kafka` at line 27708. Adds `messaging.kafka.message.key`,
  `messaging.kafka.offset`, `messaging.kafka.message.tombstone`,
  `messaging.kafka.destination.partition` (a deprecated alias for
  `messaging.destination.partition.id` — flagged in the audit).
* **Minimal trace attributes for messaging** —
  `-- $attributes_messaging_trace_minimal` at line 27014. Names the *required*
  set on every messaging span: `messaging.operation.name`, plus conditionally
  required `messaging.operation.type`, `messaging.destination.name`,
  `messaging.message.id`, `server.address`, `server.port`.
* **Database client spans** — `-- $span_db_client` at line 19833, plus
  `-- $span_db_postgresql_client` at line 19908 (PostgreSQL-specific
  guidance, namespace/error code handling), and the trace-attribute groups
  `-- $trace_db_common_minimal` (line 19710), `-- $trace_db_common_query`
  (line 19729), `-- $trace_db_common_queryAndCollection` (line 19760),
  `-- $trace_db_common_full` (line 19797).
* **Error attributes** — `-- $registry_error` at line 26956. Defines
  `error.type` (stable) and the deprecated `error.message` (line 26991).

The list of authoritative Haskell identifiers the audit will reference:

```text
messaging_system, messaging_operation_type, messaging_operation_name,
messaging_destination_name, messaging_destination_partition_id,
messaging_destination_subscription_name, messaging_destination_template,
messaging_destination_anonymous, messaging_destination_temporary,
messaging_message_id, messaging_message_conversationId,
messaging_message_envelope_size, messaging_message_body_size,
messaging_batch_messageCount, messaging_client_id,
messaging_consumer_group_name,
messaging_kafka_message_key, messaging_kafka_offset,
messaging_kafka_message_tombstone,
db_system_name, db_operation_name, db_namespace, db_collection_name,
db_query_text, db_query_summary, db_response_statusCode, db_response_returnedRows,
error_type, otel_statusCode, otel_statusDescription
```

All of those live in `OpenTelemetry.SemanticConventions`; the Haskell
identifier shape is `dotted.name` → `dotted_name` with camel-case where the
spec uses underscores in segments (so `messaging.batch.message_count` is
`messaging_batch_messageCount`). See
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/docs/OpenTelemetry-Semantic-Conventions-Guide.md`
for the rule.

### Why we don't reuse `hs-opentelemetry-instrumentation-hw-kafka-client`

The `hs-opentelemetry-instrumentation-hw-kafka-client` package exists at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/instrumentation/hw-kafka-client/`
and instruments `Kafka.Producer.produceMessage` / `Kafka.Consumer.pollMessage`
directly. `keiro` does not call those functions — it produces a transport-neutral
`KafkaProducerRecord` (`src/Keiro/Outbox/Kafka.hs:46`) and hands it to a
caller-supplied `publish` function. The actual `produceMessage` call lives
in the integration-test package (and in any future application). So `keiro`
must instrument its own seam (the outbox-publish boundary), but it can copy
the kafka package's *attribute set* and *span-name conventions* verbatim. The
audit document records that correspondence.

### The dependency graph after this plan

`keiro.cabal` will gain (Milestone 2):

* `hs-opentelemetry-api ^>= 0.2` — the `Tracer`, `Span`, `inSpan`,
  `addAttributes`, `AttributeKey` types.
* `hs-opentelemetry-semantic-conventions ^>= 0.1` — the generated attribute
  keys.
* `unliftio-core ^>= 0.2` — `MonadUnliftIO`, required by `inSpan`.

The test stanza will additionally pull in:

* `hs-opentelemetry-sdk ^>= 0.1` — `TracerProvider` for the in-memory tests.
* `hs-opentelemetry-exporter-in-memory ^>= 0.1` — captures spans for assertion.
* `hs-opentelemetry-propagator-w3c ^>= 0.1` — used to verify propagation
  round-trips.

Version bounds will be confirmed against the actual `*.cabal` of each
sub-package once Milestone 2 begins (e.g.
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/hs-opentelemetry-api.cabal`)
and the bounds in the plan updated if needed.

The application is responsible for supplying a `Tracer` (via
`getGlobalTracerProvider` or an explicit one); the library does not initialize
the global provider. When no provider is configured, `hs-opentelemetry-api`
returns a noop tracer, so `inSpan` becomes a free pass-through.

### Where the audit document lives

`docs/research/opentelemetry-semconv-audit.md`. The `docs/research/` directory
exists and houses prior design exercises; new audit lives there as a sibling.
The document is checked in and the source of truth for what to assert in the
instrumentation tests.


## Plan of Work

The work is sliced into nine milestones. Milestones 1 and 2 stand alone and
unblock everything else. Milestones 3 and 4–6 layer on top of Milestone 2.
Milestones 7 and 8 polish the surface. Milestone 9 is the closing sweep.

### Milestone 1 — Conformance audit document

**Scope.** Author `docs/research/opentelemetry-semconv-audit.md`. No code
changes.

**At the end of this milestone.** A single Markdown document under
`docs/research/` is checked in. It has one top-level `##` section per
instrumentation site listed in §Context and Orientation, plus a closing
"Compliance table" section that maps each site to the `OpenTelemetry.SemanticConventions`
section anchor it references.

Each per-site section follows this skeleton:

```text
## <Site name, e.g. Outbox publish>

**File:** `src/Keiro/Outbox.hs:228` — `publishClaimedOutbox`.

**Span name:** `"send <destination>"`.

**Span kind:** `Producer`.

**Required attributes (citation: -- $attributes_messaging_trace_minimal,
`OpenTelemetry.SemanticConventions` line 27014):**
- `messaging.operation.name` — `messaging_operation_name`. Value: `"send"`.
- `messaging.system` — `messaging_system`. Value: `"kafka"`.

**Conditionally required:**
- `messaging.destination.name` — `messaging_destination_name`. Value:
  `IntegrationEvent.destination`.
- `messaging.message.id` — `messaging_message_id`. Value: `IntegrationEvent.messageId`.
- `messaging.kafka.message.key` — `messaging_kafka_message_key`. Value:
  `IntegrationEvent.key` when present and UTF-8 decodable.
- `messaging.batch.message_count` — `messaging_batch_messageCount`. Only if
  the publisher batches.

**Recommended:**
- `messaging.destination.partition.id` — `messaging_destination_partition_id`.
- `messaging.client.id` — `messaging_client_id`.

**Error handling (citation: -- $registry_error, line 26956):**
- On `PublishFailed`: set `error.type` to a low-cardinality classifier
  (`"publish_failed"` for transport errors, `"dead_letter"` for max-attempts).
- Set span status to `Error` with the message text in the status description.

**Gap as of <date>:** No span emitted. Trace context columns exist but are
opaque pass-through. The `traceparent` is never built from a real span.

**Action:** Milestone 4 wraps the per-row body of `publishClaimedOutbox` in
`Keiro.Telemetry.withProducerSpan`.
```

**Acceptance.** A reader can `wc -l docs/research/opentelemetry-semconv-audit.md`
and see roughly 300+ lines. Every site listed in §Context and Orientation has a
corresponding `## ` section. Every Haskell identifier the document cites
appears in `OpenTelemetry.SemanticConventions` (verifiable with `grep "^<name>
::" /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`).

### Milestone 2 — Add the tracing dependencies

**Scope.** Edit `keiro.cabal` and (if needed) `cabal.project`.

**At the end of this milestone.** `cabal build all` from the repo root
succeeds with three new entries in the library `build-depends` of `keiro.cabal`
and three new entries in the test stanza. The added entries are listed in the
Interfaces and Dependencies section below; their version bounds are confirmed
against the on-disk `*.cabal` of each sub-package.

`cabal.project` already pins `mori`-style local paths for `keiki`, `kiroku`,
etc. (see `cabal.project` lines 1–13); add a `packages:` entry pointing at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api`,
`/.../semantic-conventions`, `/.../sdk`, `/.../exporters/in-memory`, and
`/.../propagators/w3c` if the packages are not on Hackage in a version the
solver can pick. Confirm by running `cabal build keiro` and observing it links
without resolver errors.

**Acceptance.**

```bash
cabal build all
```

prints `Building library for keiro-0.1.0.0..` and `Building test suite
keiro-test...` and exits 0. `cabal exec -- ghc-pkg list | grep
hs-opentelemetry` shows the new packages registered.

### Milestone 3 — Introduce `Keiro.Telemetry`

**Scope.** New module `src/Keiro/Telemetry.hs` plus
`test/Keiro/TelemetrySpec.hs`.

**At the end of this milestone.** The module exports the helpers described in
§Interfaces and Dependencies. None of it is *called* by other `Keiro.*`
modules yet; it sits alongside them as an opt-in surface. The test suite
covers three properties: (a) under a noop tracer, `withProducerSpan` calls
the body once and returns its value with no side effects on the global
`TracerProvider`; (b) the Haskell identifier `messaging_system` round-trips
to the spec string `"messaging.system"` (and the same for every other key the
module references); (c) `traceContextFromHeaders` extracts a non-empty
`SpanContext` from a sample `traceparent` header.

**Acceptance.**

```bash
cabal test keiro-test --test-options='--match "Keiro.Telemetry"'
```

prints `3 examples, 0 failures` (or more, as the test suite grows during
implementation).

### Milestone 4 — Instrument `Keiro.Outbox` and `Keiro.Outbox.Kafka`

**Scope.** Wrap the per-row body of `publishClaimedOutbox`
(`src/Keiro/Outbox.hs:244–269`) in `Keiro.Telemetry.withProducerSpan`. Add a
new optional `tracer :: !(Maybe Tracer)` field to `OutboxPublishOptions` (the
type is in `src/Keiro/Outbox/Types.hs`; verify and add the field there).
`defaultOutboxPublishOptions` sets it to `Nothing`. The span carries the
attributes listed in the audit document for "Outbox publish".

A new test in `test/Keiro/OutboxTelemetrySpec.hs` builds an in-memory
exporter-backed `TracerProvider`, configures `OutboxPublishOptions` with that
tracer, claims and publishes one row through a stub `publish` function, and
asserts the captured `ImmutableSpan` carries:

* span name `"send orders.v1"`;
* span kind `Producer`;
* attribute `messaging.system = "kafka"`;
* attribute `messaging.operation.type = "publish"`;
* attribute `messaging.operation.name = "send"`;
* attribute `messaging.destination.name = "orders.v1"`;
* attribute `messaging.message.id = <messageId>`;
* attribute `messaging.kafka.message.key = <key>` (when the test row supplies
  one);
* span status `Ok` on success;
* span status `Error` + `error.type = "publish_failed"` when the stub returns
  `PublishFailed`.

**Acceptance.**

```bash
cabal test keiro-test --test-options='--match "Keiro.Outbox.Telemetry"'
```

prints all green.

### Milestone 5 — Instrument `Keiro.Inbox` and `Keiro.Inbox.Kafka`

**Scope.** In `src/Keiro/Inbox/Kafka.hs`, after `integrationEventFromKafka`
succeeds and before the user handler runs, extract the parent context from
the W3C propagator using the inbound `headers` (the same list already
threaded through). Open a `Consumer`-kind span as a child of that context,
named `"process <topic>"`, carrying the attributes listed in the audit
document for "Inbox consume" / "Inbox process".

The hookup is structured so the consumer span surrounds the user's processing
handler, not just the decode call — the span's purpose is to capture
processing time, not parser time. The decode itself is fast and is recorded
as a span event named `decode`.

A new test in `test/Keiro/InboxTelemetrySpec.hs` uses the in-memory exporter
to:

1. Run a producer span end-to-end via Milestone 4's helpers, capturing the
   emitted `traceparent` from the resulting Kafka header list.
2. Feed those headers into `integrationEventFromKafka` and confirm the
   resulting consumer span is a *child* of the producer span (same trace id,
   different span id, producer span id is the consumer's parent).

**Acceptance.** The same test command as Milestone 4 plus the new
`Keiro.Inbox.Telemetry` match.

### Milestone 6 — Instrument `Keiro.Command`

**Scope.** Wrap `runCommand`, `runCommandWithSql`, `runCommandWithSqlEvents`
in `src/Keiro/Command.hs:250–339` in `Keiro.Telemetry.withCommandSpan` (a new
helper added to `Keiro.Telemetry` for symmetry with the producer/consumer
helpers — see §Interfaces and Dependencies). The span name is the resolved
stream name; attributes include `keiro.stream.name`, `keiro.retry.attempt`,
and, on the append result, `keiro.events.appended`.

Because keiro itself does not call hasql directly inside `runCommand` (it
delegates to `kiroku-store`), the `db.system.name = "postgresql"` attribute
is set on the outer span — `kiroku` will eventually pick up
`hasql-opentelemetry` on its side; we leave a `<!-- TODO -->` note pointing
to that follow-up in the audit document.

**Acceptance.** A new in-memory-exporter test that runs a contrived command
through the existing `Counter`-style test harness (see `test/Main.hs` for the
pattern) and asserts a span tree with `command → hydrate → append`. Test
command stays the same.

### Milestone 7 — Wire up the W3C propagator in `Keiro.Integration.Event`

**Scope.** Add two helpers to `Keiro.Telemetry`:

* `traceContextFromCurrentSpan :: (MonadIO m, MonadTracer m) => m (Maybe TraceContext)` —
  reads the current span context from the thread-local context, formats it
  through the W3C propagator's injector, and returns it as a
  `Keiro.Integration.Event.TraceContext`. Returns `Nothing` when no span is
  active.
* `traceContextFromHeaders :: [(Text, Text)] -> Maybe TraceContext` — already
  what `integrationEventFromKafka` does inline; lift it out so the same code
  is reused by any future HTTP-headers path.

Update `jitsurei/app/Main.hs:116` to populate `traceContext` from
`traceContextFromCurrentSpan` instead of hard-coding `Nothing`. This makes
the jitsurei guide an end-to-end working example of trace propagation.

**Acceptance.** `cabal test jitsurei-test` passes and includes a new
in-memory-exporter assertion that the trace context survives the
outbox→consume round trip in the jitsurei example.

### Milestone 8 — Guide-backed example and `docs/guides`

**Scope.** Create `docs/guides/telemetry/README.md` walking a reader through
configuring a `TracerProvider`, registering the W3C propagator, and observing
a producer→consumer trace on the console exporter. Add a matching example
under `jitsurei/src/Jitsurei/Telemetry.hs` (or similar) wired into the
existing jitsurei test suite per the conventions in
`docs/plans/18-add-guide-backed-jitsurei-examples.md`.

**Acceptance.** `cabal test jitsurei-test` exercises the new example.
`docs/guides/README.md` index references the new telemetry guide.

### Milestone 9 — Final sweep

**Scope.** Re-read `docs/research/opentelemetry-semconv-audit.md` against
the post-implementation `src/`. For every per-site section, change the
`**Gap as of <date>:**` line to `**Status:** closed — see <commit-hash>` or
to `**Status:** out of scope — see Decision Log entry on <date>`. Update
Outcomes & Retrospective on this plan with the closing summary.


## Concrete Steps

This section is updated as work proceeds. The commands below are the ones
the implementer will run repeatedly; expected output is short and pasted as
fenced `text` blocks.

### Inspecting the semantic-conventions module

```bash
grep -n "^messaging_system ::\|^messaging_operation_type ::\|^messaging_destination_name ::" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

Expected output (paraphrased):

```text
27693:messaging_operation_type :: AttributeKey Text
27705:messaging_system :: AttributeKey Text
27625:messaging_destination_name :: AttributeKey Text
```

### Building after Milestone 2

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build all
```

Expected (paraphrased):

```text
Resolving dependencies...
Build profile: -w ghc-9.12.* -O1
Building library for hs-opentelemetry-api-...
Building library for hs-opentelemetry-semantic-conventions-...
Building library for keiro-0.1.0.0..
...
Building test suite keiro-test for keiro-0.1.0.0..
Linking ./dist-newstyle/.../keiro-test
```

### Running the telemetry test subset

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-test --test-options='--match "Keiro.Telemetry"'
```

Expected (paraphrased):

```text
Keiro.Telemetry
  withProducerSpan
    invokes the body and returns its value under a noop tracer  [✔]
  Attribute keys
    messaging_system has spec name "messaging.system"           [✔]
  traceContextFromHeaders
    extracts a span context from a W3C traceparent header       [✔]

Finished in 0.020 seconds
3 examples, 0 failures
```

### Verifying the producer span

The Milestone 4 test will print, on failure, the captured `ImmutableSpan`
records via `hs-opentelemetry-exporter-in-memory`'s accessor. On success the
test prints nothing extra and the `cabal test` summary is the only output.


## Validation and Acceptance

A complete implementation of this plan can be validated by a reader with no
prior context as follows.

1. From the repo root, run `cabal build all` — succeeds.
2. Run `cabal test keiro-test` — passes (existing 65 examples plus the new
   ones added by Milestones 3, 4, 5, 6).
3. Run `cabal test jitsurei-test` — passes; the new telemetry guide example
   is exercised.
4. Open `docs/research/opentelemetry-semconv-audit.md`. Every per-site
   section's `Status:` line reads `closed` or `out of scope, see Decision
   Log`. No `Gap as of …` lines remain.
5. From a fresh shell, set up a console exporter against the
   `docs/guides/telemetry/README.md` example and observe a producer span
   ending with `messaging.system=kafka` and a child consumer span with the
   same `trace_id`. The exact transcript is recorded in the guide.

Acceptance is the behavior listed above plus a Surprises & Discoveries
section that captures anything that didn't go as planned, and a Decision
Log entry for every judgement call.


## Idempotence and Recovery

Every milestone is additive: the audit document is a new file, the new
dependencies are added entries, `Keiro.Telemetry` is a new module, and each
of Milestones 4–7 wraps existing code paths in conditional helpers that
degrade to no-ops under a noop tracer. Re-running any milestone's commands
is safe.

If a milestone introduces a regression, revert the offending commit (each
milestone is its own commit per §Plan of Work) — every test file is also
new, so reverting removes both the production code and the assertions in
lock-step. Existing `cabal test keiro-test` results are unaffected by
reverting later milestones because Milestones 4–7 only add behavior; they
do not alter existing call signatures externally (the only externally
visible change is the new optional `tracer :: Maybe Tracer` field on
`OutboxPublishOptions`, which defaults to `Nothing` and is therefore
backwards-compatible at every call site that uses
`defaultOutboxPublishOptions`).


## Interfaces and Dependencies

### New module: `Keiro.Telemetry`

File: `src/Keiro/Telemetry.hs`. Exported by the cabal stanza alongside the
other `Keiro.*` modules in `keiro.cabal:33–59`.

```haskell
module Keiro.Telemetry
  ( -- * Tracer
    Tracer
  , makeTracerForKeiro

    -- * Producer / Consumer / Command helpers
  , withProducerSpan
  , withConsumerSpan
  , withCommandSpan

    -- * W3C context bridge
  , traceContextFromCurrentSpan
  , traceContextFromHeaders
  , injectTraceContext
  ) where

-- | Create the keiro tracer from a user-supplied 'TracerProvider'.
makeTracerForKeiro :: TracerProvider -> Tracer

-- | Run @m@ inside a 'Producer'-kind span named @"send " <> destination@
-- with the attributes prescribed by the messaging semantic conventions.
-- When no tracer is configured this is a thin pass-through.
withProducerSpan
  :: (MonadUnliftIO m, MonadTracer m, HasCallStack)
  => IntegrationEvent
  -> KafkaProducerRecord
  -> m a
  -> m a

-- | Symmetric helper for the consumer side. Extracts an upstream parent
-- context from the supplied Kafka headers before opening the span, so the
-- consumer span is parented under the producer span.
withConsumerSpan
  :: (MonadUnliftIO m, MonadTracer m, HasCallStack)
  => KafkaInboundRecord
  -> m a
  -> m a

-- | Internal span around a command run. Attributes describe the stream
-- name, the retry attempt, and (on completion) the number of events
-- appended.
withCommandSpan
  :: (MonadUnliftIO m, MonadTracer m, HasCallStack)
  => Text          -- ^ resolved stream name
  -> m a
  -> m a

-- | Read the current span context off the thread-local context and format
-- it through the W3C TraceContext propagator. Returns 'Nothing' when no
-- span is active.
traceContextFromCurrentSpan
  :: (MonadIO m) => m (Maybe TraceContext)

-- | Pure header-extraction; mirror image of 'injectTraceContext'.
traceContextFromHeaders :: [(Text, Text)] -> Maybe TraceContext

-- | Append the @traceparent@/@tracestate@ headers for the active span to
-- the given header list. Used by adapters that build Kafka headers from
-- their own envelope.
injectTraceContext
  :: (MonadIO m) => [(Text, Text)] -> m [(Text, Text)]
```

### Modified type: `OutboxPublishOptions`

File: `src/Keiro/Outbox/Types.hs`. Add one optional field:

```haskell
data OutboxPublishOptions = OutboxPublishOptions
  { ... -- existing fields preserved verbatim
  , tracer :: !(Maybe Tracer)
  }

defaultOutboxPublishOptions :: OutboxPublishOptions
defaultOutboxPublishOptions = OutboxPublishOptions { ..., tracer = Nothing }
```

### Modified call site: `publishClaimedOutbox`

File: `src/Keiro/Outbox.hs:228`. The body of the per-row branch in
`drainBatch` is wrapped:

```haskell
withProducerSpan (row ^. #event) (outboxRowToKafkaRecord row) $ do
  outcome <- publish row
  ...
```

When `options ^. #tracer` is `Nothing`, the helper passes through.

### Modified call site: `integrationEventFromKafka`

File: `src/Keiro/Inbox/Kafka.hs:86`. The decode itself stays pure; the
consumer span is opened *outside* the decode by the inbox runner (the new
helper `withConsumerSpan` takes the `KafkaInboundRecord` and the user
handler). This keeps the pure decode function pure.

### Cabal-level dependencies

`keiro.cabal` library `build-depends` gains:

```cabal
hs-opentelemetry-api >= 0.2,
hs-opentelemetry-semantic-conventions >= 0.1,
unliftio-core >= 0.2,
```

`keiro-test` `build-depends` gains:

```cabal
hs-opentelemetry-sdk >= 0.1,
hs-opentelemetry-exporter-in-memory >= 0.1,
hs-opentelemetry-propagator-w3c >= 0.1,
```

The on-disk packages are at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/{api,semantic-conventions,sdk,exporters/in-memory,propagators/w3c}/`.
If the version bounds above do not match the versions in those `*.cabal`
files, Milestone 2 adjusts the bounds and records the adjustment in the
Decision Log.

### Out of scope (explicit non-goals)

* **Instrumenting hasql itself.** That is `hasql-opentelemetry`'s job
  (`/Users/shinzui/Keikaku/bokuno/hasql-opentelemetry`). The audit notes its
  existence as a follow-up but does not pull it in.
* **Metrics.** This plan covers spans only. Metrics
  (`metric.messaging.client.operation.duration`, etc.) are a separate audit.
* **Logs and log-exception events.** Same — separate work.
* **A keiro-specific exporter.** The library only emits spans through the
  global provider; exporter configuration is the application's
  responsibility.
* **Backwards-compatibility shims for the deprecated `messaging.operation`
  attribute.** Per Decision Log, we use the current `messaging.operation.type`
  / `messaging.operation.name` pair and do not also emit the deprecated key.
