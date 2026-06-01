# OpenTelemetry semantic-conventions audit

This document audits every place in the `keiro` library where OpenTelemetry
instrumentation should exist according to the **OpenTelemetry semantic
conventions**, and records what is currently emitted versus what the spec
requires. Each per-site section names the file and call site, the span name
and kind, the required, conditionally required, and recommended attributes
(citing the Haskell `AttributeKey` identifier exported from
`OpenTelemetry.SemanticConventions`), the spec section anchor in the
generated module, and a gap-vs.-action line.

The source of truth for the Haskell binding is

```text
/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

(29,049 lines, `v1.40` of the upstream spec). Spec citations in this document
point at the `-- $<anchor>` Haddock chunks inside that file.

**Version note (updated 2026-06-01):** keiro now depends on
`hs-opentelemetry-semantic-conventions >= 1.40` directly (see
`docs/plans/32-upgrade-to-hs-opentelemetry-1-0-and-align-to-latest-opentelemetry-semantic-conventions.md`).
Every typed `AttributeKey` this document cites is imported directly from
`OpenTelemetry.SemanticConventions`; the prior vendoring workaround in
`Keiro.Telemetry` (which copied keys absent from the old `0.1.0.0` Hackage
release) has been removed. Only the bespoke `keiro.*` keys
(`keiro_stream_name`, `keiro_retry_attempt`, `keiro_events_appended`) are
defined locally, as they have no upstream equivalent. The citations below
were already pinned to the canonical v1.40 module and now match the linked
release exactly.

Citation legend (anchor → line):

| Haddock anchor                              | Line  | Coverage                                                                 |
| ------------------------------------------- | ----- | ------------------------------------------------------------------------ |
| `-- $attributes_messaging_trace_minimal`    | 27014 | Required and conditionally required attrs on every messaging span        |
| `-- $messaging_attributes`                  | 27047 | Full messaging attribute group (system, destination, batch, client id)   |
| `-- $messaging_kafka`                       | 27197 | Kafka-flavored messaging span guidance                                   |
| `-- $registry_messaging_kafka`              | 27708 | Kafka-specific attribute definitions (key, offset, tombstone)            |
| `-- $registry_messaging_deprecated`         | 3413  | Legacy `messaging.operation` (not used; see Decision Log)                |
| `-- $trace_db_common_minimal`               | 19710 | Required db span attrs                                                   |
| `-- $trace_db_common_query`                 | 19729 | Adds `db.query.text` / `db.query.summary`                                 |
| `-- $trace_db_common_queryAndCollection`    | 19760 | Adds `db.collection.name`                                                |
| `-- $trace_db_common_full`                  | 19797 | Adds `db.response.*` and `db.operation.*`                                |
| `-- $span_db_client`                        | 19833 | Database-client span shape                                               |
| `-- $span_db_postgresql_client`             | 19908 | PostgreSQL-specific guidance                                             |
| `-- $registry_error`                        | 26956 | `error.type` attribute                                                   |

The per-site sections below reference these anchors by name; the `keiro` value
to assign each attribute is named explicitly so the Milestone 4–6 tests can
assert against it.

The audit was authored before code instrumentation began. Every per-site
section ends in a `**Gap as of 2026-05-19:**` line that Milestone 9 will
reconcile against the post-implementation `src/`.


## Outbox enqueue

**File:** `src/Keiro/Outbox.hs:79` — `enqueueIntegrationEventTx`; same module
at line 195 — `enqueueProducerEventTx`; `src/Keiro/Outbox/Schema.hs:100` —
`enqueueOutboxTx` (the low-level row insertion the two helpers share).

**Span name:** `create <destination>` — the spec's recommended verb for
"the application created a message but has not yet sent it".

**Span kind:** `Internal`. The enqueue happens entirely inside the caller's
`hasql-transaction` `Tx.Transaction`; no traffic crosses the network at this
point, so `Producer` is wrong (the producer span is opened later by the
publisher worker, see "Outbox publish" below).

**Required attributes (citation: `-- $attributes_messaging_trace_minimal`,
line 27014):**

- `messaging.operation.name` — `messaging_operation_name`. Value: `"create"`.
- `messaging.system` — `messaging_system`. Value: `"kafka"` (`keiro`'s only
  outbound transport today).

**Conditionally required:**

- `messaging.operation.type` — `messaging_operation_type`. Value: `"create"`
  (the spec value for "create a message but do not send it").
- `messaging.destination.name` — `messaging_destination_name`. Value:
  `event ^. #destination`.
- `messaging.message.id` — `messaging_message_id`. Value: `event ^. #messageId`.

**Recommended:**

- `messaging.kafka.message.key` — `messaging_kafka_message_key`. Value:
  `event ^. #key`, when present (and UTF-8 decodable).
- `messaging.client.id` — `messaging_client_id`. Value: a stable application
  identifier when the caller supplies one (not currently captured in
  `keiro`; producers may set it via a span attribute decorator).

**Error handling (citation: `-- $registry_error`, line 26956):**

- `enqueueOutboxTx` returns unit; failures bubble up as `Tx.Transaction`
  errors and surface on the surrounding command span (see "Command run"
  below). Set `error.type` to `"db_insert_failed"` if a wrapping helper
  catches the exception locally.

**Gap as of 2026-05-19:** No span emitted. The enqueue runs inside the
caller's hasql transaction and is observable only as a row in
`keiro_outbox`. The `traceparent` columns on the row are written from the
caller's `IntegrationEvent.traceContext`, which today is always `Nothing`
(no upstream constructs it from a real span).

**Action:** Out of scope for Milestone 4 to keep the patch small. The
follow-up to instrument the enqueue is filed under [[milestone-9-followups]]
in the Decision Log; the current plan covers the publisher-side span (which
is the higher-value signal for dashboards because it captures broker latency
and retries).


## Outbox publish

**File:** `src/Keiro/Outbox.hs:228` — `publishClaimedOutbox`, with the
per-row body at `src/Keiro/Outbox.hs:244–269`; the `KafkaProducerRecord`
shape is built in `src/Keiro/Outbox/Kafka.hs:55` — `outboxRowToKafkaRecord`.

**Span name:** `send <destination>`. The `<destination>` is
`row ^. #event ^. #destination` (the Kafka topic name).

**Span kind:** `Producer`. This is the main producer-side span.

**Required attributes (citation: `-- $attributes_messaging_trace_minimal`,
line 27014):**

- `messaging.operation.name` — `messaging_operation_name`. Value: `"send"`.
- `messaging.system` — `messaging_system`. Value: `"kafka"`.

**Conditionally required:**

- `messaging.operation.type` — `messaging_operation_type`. Value: `"publish"`
  (spec value for "send a message to a destination").
- `messaging.destination.name` — `messaging_destination_name`. Value:
  `row ^. #event ^. #destination`.
- `messaging.message.id` — `messaging_message_id`. Value:
  `row ^. #event ^. #messageId`.

**Recommended (citation: `-- $messaging_attributes`, line 27047 and
`-- $registry_messaging_kafka`, line 27708):**

- `messaging.kafka.message.key` — `messaging_kafka_message_key`. Value:
  `row ^. #event ^. #key`, when present (and UTF-8 decodable).
- `messaging.destination.partition.id` — `messaging_destination_partition_id`.
  Optional; populated only if a future publisher returns the chosen
  partition.
- `messaging.client.id` — `messaging_client_id`. Optional; the application
  is expected to supply this on the `Tracer` instance via a resource
  attribute rather than per-span.
- `messaging.batch.message_count` — `messaging_batch_messageCount`. Not
  applicable to keiro today: `publishClaimedOutbox` calls `publish` once
  per row.

**Error handling (citation: `-- $registry_error`, line 26956):**

- On `PublishFailed`: set `error.type` to a low-cardinality classifier:
  `"publish_failed"` for transient transport errors (row will be retried) /
  `"dead_letter"` when `markOutboxFailedTx` returns `OutboxDead` (row has
  exhausted `maxAttempts`).
- Set span status to `Error` with the failure text in the description.

**Gap as of 2026-05-19:** No span emitted. The `IntegrationEvent.traceContext`
field is serialized to `traceparent` / `tracestate` Kafka headers verbatim
(see `src/Keiro/Integration/Event.hs:196–200`), but it is never *constructed*
from a real span context: the only producer of the field is the application,
and the jitsurei example at `jitsurei/app/Main.hs:116` hardcodes `Nothing`.

**Action:** Milestone 4 wraps the per-row body of `publishClaimedOutbox` in
`Keiro.Telemetry.withProducerSpan`. The Milestone 7 propagator wiring
replaces the `Nothing` literal with an extraction from the active span.


## Inbox consume

**File:** `src/Keiro/Inbox/Kafka.hs:86` — `integrationEventFromKafka`. The
decode is pure; the consumer span is opened by the inbox runner around the
*user handler* that consumes the decoded event, not inside the decoder.

**Span name:** `process <destination>`. The `<destination>` matches the
Kafka topic from the inbound record (`record ^. #topic`), which equals the
producer-side `destination` after round-tripping through the
`keiro-destination` header.

**Span kind:** `Consumer`.

**Parenting:** The span is parented under the *upstream* producer span. The
parent context is extracted from the inbound Kafka headers using the W3C
TraceContext propagator (the `traceparent` and `tracestate` header names
defined at `src/Keiro/Integration/Event.hs:227–229`) *before* the consumer
span opens.

**Required attributes (citation: `-- $attributes_messaging_trace_minimal`,
line 27014):**

- `messaging.operation.name` — `messaging_operation_name`. Value: `"process"`.
- `messaging.system` — `messaging_system`. Value: `"kafka"`.

**Conditionally required:**

- `messaging.operation.type` — `messaging_operation_type`. Value: `"process"`.
- `messaging.destination.name` — `messaging_destination_name`. Value:
  `record ^. #topic`.
- `messaging.message.id` — `messaging_message_id`. Value:
  `event ^. #messageId` (set on the span *after* decode succeeds; missing
  when the decode fails — in that case set `error.type` instead).

**Recommended (citation: `-- $messaging_attributes`, line 27047 and
`-- $registry_messaging_kafka`, line 27708):**

- `messaging.destination.partition.id` — `messaging_destination_partition_id`.
  Value: `Text.pack (show (record ^. #partition))`.
- `messaging.kafka.offset` — `messaging_kafka_offset`. Value:
  `record ^. #offset`.
- `messaging.kafka.message.key` — `messaging_kafka_message_key`. Value:
  `record ^. #key`, when present.
- `messaging.consumer.group.name` — `messaging_consumer_group_name`. Value:
  the consumer group identifier the application supplies. Not currently
  captured on `KafkaInboundRecord`; the inbox runner can take it from its
  Shibuya/`shibuya-kafka-adapter` configuration and pass it explicitly to
  `withConsumerSpan`.

**Decode-failure handling (citation: `-- $registry_error`, line 26956):**

- On `MissingHeader`: set `error.type = "missing_header"` and the header
  name on the span description.
- On `InvalidIntHeader` / `InvalidUuidHeader`: set
  `error.type = "invalid_header"`.

**Gap as of 2026-05-19:** No span emitted. The decode is pure and the
`traceContext` returned in the decoded `IntegrationEvent` is opaque
metadata — no downstream consumer uses it to parent a span.

**Action:** Milestone 5 opens a `Consumer`-kind span around the user
handler in the inbox runner. The runner extracts the upstream context via
the W3C propagator before opening the span. Decode itself stays pure; if
decode fails the runner records the error on the consumer span.


## Inbox process

**File:** the application-supplied handler that runs after
`integrationEventFromKafka` succeeds. Covered by the consumer span opened
in the previous section; the user can open further `Internal` spans as
they please.

**Span name:** Inherited — the consumer span surrounds the handler. The
user may open child `Internal` spans named after their own business
operations.

**Span kind:** Child spans are `Internal`.

**Attributes:** Application-specific. The keiro library makes no claim on
this surface beyond the parent consumer span.

**Gap as of 2026-05-19:** No span emitted. Same root cause as "Inbox
consume" — no consumer span exists for child spans to attach to.

**Action:** Closed transitively by Milestone 5; once the consumer span is
open, application-level child spans are the user's responsibility.


## Command run

**Files:**

- `src/Keiro/Command.hs:250` — `runCommand`.
- `src/Keiro/Command.hs:286` — `runCommandWithSql`.
- `src/Keiro/Command.hs:298` — `runCommandWithSqlEvents`.

**Span name:** the resolved stream name —
`(eventStream ^. #resolveStreamName) targetStream`. Example: a counter
command targeting stream `counter-7` produces a span named `counter-7`.

**Span kind:** `Internal`.

**Attributes (keiro-specific; spec does not define a "command" span kind):**

- `keiro.stream.name` — bespoke key; value as above.
- `keiro.retry.attempt` — bespoke key; value: `(options ^. #retryLimit) -
  remaining + 1`. Recorded on the span at each `attempt` call.
- `keiro.events.appended` — bespoke key; value: `Prelude.length encoded`
  on success.

**Database sub-span (citation: `-- $span_db_client`, line 19833;
`-- $trace_db_common_minimal`, line 19710):**

- `db.system.name` — `db_system_name`. Value: `"postgresql"`. Set on the
  outer command span as a leading attribute so dashboards that filter on
  `db.system.name = postgresql` still pick it up while `kiroku` itself
  remains uninstrumented.
- `db.namespace` — `db_namespace`. Value: the configured database name.
  Optional; the application passes it via a tracer resource attribute.
- `db.collection.name` — `db_collection_name`. Not applicable on the
  command span (the command writes through `kiroku-store`'s
  `appendToStream`; the per-table view belongs on a future
  `hasql-opentelemetry` span).

**Error handling (citation: `-- $registry_error`, line 26956):**

- On a returned `Left CommandError`: set `error.type` to one of the
  `CommandError` constructor names (`"validation_failed"`,
  `"version_conflict"`, `"store_error"`).
- On exception escape: set `error.type = "exception"` and let
  `hs-opentelemetry-api`'s default exception recording attach the type.

**Gap as of 2026-05-19:** No span emitted. The command runner is one of
the highest-value places to add a span because every retry, every hydrate,
and every snapshot read currently has no visible attribution.

**Action:** Milestone 6 wraps each of the three `runCommand*` entry points
in `Keiro.Telemetry.withCommandSpan`. The `Maybe Tracer` opt-in does not
extend here — the helper degrades to a no-op under
`hs-opentelemetry-api`'s noop tracer, so calling it unconditionally costs
nothing in the no-tracer path.

> **Follow-up:** Once `hasql-opentelemetry` is wired into `kiroku-store`,
> the actual per-statement database spans appear as children of the
> command span. That work is tracked under
> `/Users/shinzui/Keikaku/bokuno/hasql-opentelemetry` and explicitly out
> of scope for this plan.


## Hydration

**Files:**

- `src/Keiro/Command.hs:96` — `hydrate`.
- `src/Keiro/Command.hs:181` — `hydrateFull`.

**Span name:** `hydrate <stream>`. Child of the surrounding command span.

**Span kind:** `Internal`.

**Attributes:**

- `keiro.stream.name` — the resolved stream name (mirrored from the
  parent for filterability).
- `keiro.hydrate.page_size` — page size used during replay
  (`options ^. #hydratePageSize` or equivalent).
- `keiro.events.replayed` — count of events fed through the fold to
  arrive at the hydrated state.

**Snapshot child (when used; see next section):** A nested span around
the snapshot read/write, named per the next section.

**Gap as of 2026-05-19:** No span emitted; hydration is silent except in
log lines.

**Action:** Out of scope for the current plan's instrumentation milestones
(M4–M7) to keep the patch small. The `Keiro.Telemetry.withCommandSpan`
wrapper opened in Milestone 6 already attributes the work to the command;
splitting hydrate out as its own child can land as a follow-up once the
command span is in production. Tracked under [[milestone-9-followups]].


## Snapshot read / write

**File:** `src/Keiro/Snapshot.hs:27` — `hydrateWithSnapshot`; same module
at line 47 — `writeSnapshot`.

**Span name:** `snapshot.read <stream>` and `snapshot.write <stream>`.

**Span kind:** `Internal`. Child of the surrounding command span.

**Attributes:**

- `keiro.stream.name` — the resolved stream name.
- `keiro.snapshot.stream_version` — `streamVersion` value (write only).

**Gap as of 2026-05-19:** No span emitted.

**Action:** Out of scope for M4–M7; tracked under [[milestone-9-followups]].
The command span captures the wall-clock time the snapshot path consumes;
a dedicated child is cosmetic until snapshots become a bottleneck.


## Read-model rebuild

**File:** `src/Keiro/ReadModel/Rebuild.hs:13` — `rebuild`.

**Span name:** `rebuild <read-model>`. The `<read-model>` is taken from
the read-model's metadata identity.

**Span kind:** `Internal`.

**Attributes:**

- `keiro.readmodel.name` — bespoke key.
- `db.collection.name` — `db_collection_name`. Value: the SQL table the
  read model writes into. Useful when filtering rebuild slowness by
  table.

**Gap as of 2026-05-19:** No span emitted.

**Action:** Out of scope for M4–M7; tracked under [[milestone-9-followups]].


## Projection apply

**File:** `src/Keiro/Projection.hs:1` — the module-level apply path.

**Span name:** `apply <projection>`.

**Span kind:** `Internal`.

**Attributes:**

- `keiro.projection.name` — bespoke key.
- `keiro.events.consumed` — number of events handed to the projection
  during the call.

**Gap as of 2026-05-19:** No span emitted.

**Action:** Out of scope for M4–M7; tracked under [[milestone-9-followups]].


## Timer fire

**File:** `src/Keiro/Timer.hs:1` — the module-level timer dispatch.

**Span name:** `timer.fire <timer-id>`.

**Span kind:** `Internal`.

**Attributes:**

- `keiro.timer.id` — bespoke key.
- `keiro.timer.scheduled_for` — RFC3339 timestamp of the original
  scheduling.

**Gap as of 2026-05-19:** No span emitted.

**Action:** Out of scope for M4–M7; tracked under [[milestone-9-followups]].


## Compliance table

This table is the at-a-glance summary the Milestone 9 sweep will reconcile.

| Site                | Span name pattern              | Kind     | Anchor                                       | Status as of 2026-05-19 |
| ------------------- | ------------------------------ | -------- | -------------------------------------------- | ----------------------- |
| Outbox enqueue      | `create <destination>`         | Internal | `$attributes_messaging_trace_minimal` 27014  | Gap (out of scope M4)   |
| Outbox publish      | `send <destination>`           | Producer | `$attributes_messaging_trace_minimal` 27014  | Gap → M4                |
| Inbox consume       | `process <destination>`        | Consumer | `$attributes_messaging_trace_minimal` 27014  | Gap → M5                |
| Inbox process       | (inherits consumer span)       | Internal | n/a                                          | Closed transitively M5  |
| Command run         | `<stream>`                     | Internal | `$span_db_client` 19833                      | Gap → M6                |
| Hydration           | `hydrate <stream>`             | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Snapshot read/write | `snapshot.{read,write} <s>`    | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Read-model rebuild  | `rebuild <read-model>`         | Internal | `$span_db_client` 19833                      | Gap (follow-up)         |
| Projection apply    | `apply <projection>`           | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Timer fire          | `timer.fire <timer-id>`        | Internal | n/a (bespoke)                                | Gap (follow-up)         |


## Verifying the citations

Every Haskell `AttributeKey` referenced by this document is exported from
`OpenTelemetry.SemanticConventions`. To verify, run:

```bash
grep -nE "^(messaging_system|messaging_operation_type|messaging_operation_name|messaging_destination_name|messaging_destination_partition_id|messaging_message_id|messaging_consumer_group_name|messaging_kafka_message_key|messaging_kafka_offset|messaging_kafka_message_tombstone|messaging_batch_messageCount|messaging_client_id|db_system_name|db_namespace|db_collection_name|db_query_text|db_query_summary|db_response_statusCode|db_response_returnedRows|db_operation_name|error_type|otel_statusCode|otel_statusDescription) ::" \
  /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs
```

The output names each identifier and its line in the generated module,
matching the citations above.


## Follow-ups out of scope for this plan

Tracked here so they survive Milestone 9's sweep and feed a future audit
pass:

- **`milestone-9-followups`** — the hydration, snapshot, read-model
  rebuild, projection, and timer sites listed above. Their command-span
  ancestor (Milestone 6) already attributes their wall-clock time; the
  per-step child spans are cosmetic until profiling demands them.
- **`hasql-opentelemetry` adoption** — once `kiroku-store` depends on it,
  every command-span run will gain per-statement database children
  automatically, closing the `db.collection.name` and `db.query.text`
  gaps on this audit without `keiro` code changes.
- **Metrics audit** — separate from this plan.
- **Log / exception audit** — separate from this plan.
