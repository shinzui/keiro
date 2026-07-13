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
(`keiro_stream_name`, `keiro_retry_attempt`, `keiro_events_appended`,
`keiro_replay_divergence`) are defined locally, as they have no upstream
equivalent. The citations below were already pinned to the canonical v1.40
module and now match the linked release exactly.

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
- `keiro.replay.divergence` — bespoke key; present only when the
  just-appended batch cannot replay from the pre-command state. The bounded
  text value is `event_index=<n>;reason=<class>`, where the reason class is one
  of `no_inverting_edge`, `ambiguous_inversions`, `queue_mismatch`, or
  `log_truncated`. It is a post-commit advisory and does not change the
  command's successful span status.

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


## Workflow run

**File:** `src/Keiro/Workflow.hs` — `runWorkflowWith` (the handler body); the
per-step span uses the same helper with a `Just stepName`.

**Span name:** `workflow <workflow-name>`.

**Span kind:** `Internal`. The workflow runs entirely in-process; no network
boundary is crossed by the runtime itself.

**Attributes (keiro-specific; spec defines no "workflow" span):**

- `keiro.workflow.name` — bespoke key; value: the `WorkflowName`.
- `keiro.workflow.id` — bespoke key; value: the `WorkflowId`.
- `keiro.workflow.step` — bespoke key; value: the `StepName`, set only when the
  span wraps a single step or a resume (omitted on the whole-run span).

**Gap as of 2026-06-03:** opened by EP-44 via
`Keiro.Telemetry.withWorkflowSpan`, threaded through `WorkflowRunOptions.tracer`.


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
| Workflow run        | `workflow <name>`              | Internal | n/a (bespoke)                                | Gap → EP-44             |


## Metrics

This section catalogues the twenty metric instruments keiro records. They are
defined in `keiro/src/Keiro/Telemetry.hs` by
`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`
(EP-33) as the `KeiroMetrics` record built by `newKeiroMetrics`, and recorded
through the `record*` helpers at the worker call sites added by EP-35 (outbox +
inbox) and EP-36 (timer + projection). The six `keiro.workflow.*` instruments
were added by EP-44 (workflow observability) and are recorded by the v2 workflow
runtime and resume worker. The names, units, kinds, and description strings
below match `newKeiroMetrics` character-for-character; EP-35/EP-36/EP-37/EP-44
reference them verbatim.

The instrument **kind** policy: backlog and lag are synchronous gauges recorded
by each worker on every poll pass using the count/age it already computes with
its `Store` effect (an observable gauge's callback would need its own database
access, which the library does not own — see the MasterPlan Decision Log); tally
instruments are monotonic counters recorded inline; distributions are histograms.

Unit strings follow UCUM-style annotations: `{event}`, `{message}`, `{timer}`,
`{attempt}`, `{timeout}` for dimensionless counts, and `ms` for the fire-lag
duration.

The OpenTelemetry messaging-metric semantic conventions are client
send/consume/duration oriented, not queue-depth oriented, so only the
published/processed counters have a (loose) spec analogue; the backlog gauges,
the timer instruments, and the projection instruments have **no** messaging-metric
equivalent and live in the bespoke `keiro.*` namespace, exactly as the bespoke
`keiro_*` attribute keys do for spans. The spec anchors cited below are in the
generated module
`hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`.

### Outbox

- **`keiro.outbox.backlog`** — unit `{event}`, **Gauge** (`Int64`). Recorded by
  the outbox publisher each poll pass (`recordOutboxBacklog`) with the count of
  `keiro_outbox` rows awaiting publish. Description: "Outbox rows awaiting
  publish." Semconv alignment: none (queue depth; no messaging-metric
  equivalent).
- **`keiro.outbox.published`** — unit `{event}`, **Counter** (`Int64`). Recorded
  on publish success (`recordOutboxPublished`). Description: "Outbox events
  successfully published." Semconv alignment:
  `$metric_messaging_client_sent_messages` (line 3407,
  `messaging.client.sent.messages`) is the closest spec metric — a counter of
  messages a producer sent. keiro uses its bespoke `keiro.outbox.published` name
  because it is event-sourcing-specific and tracks retried/deadlettered
  separately, which the spec metric does not (loose alignment).
- **`keiro.outbox.retried`** — unit `{event}`, **Counter** (`Int64`). Recorded on
  a transient publish failure that will retry (`recordOutboxRetried`).
  Description: "Outbox publish attempts that failed and will retry." Semconv
  alignment: none.
- **`keiro.outbox.deadlettered`** — unit `{event}`, **Counter** (`Int64`).
  Recorded when an event exhausts its retry budget
  (`recordOutboxDeadlettered`). Description: "Outbox events parked after
  exhausting retries." Semconv alignment: none.

### Inbox

- **`keiro.inbox.processed`** — unit `{message}`, **Counter** (`Int64`). Recorded
  on handler success (`recordInboxProcessed`). Description: "Inbox messages
  processed successfully." Semconv alignment:
  `$metric_messaging_client_consumed_messages` (line 3410,
  `messaging.client.consumed.messages`) is the closest spec metric — a counter
  of messages a consumer consumed. Same note as `keiro.outbox.published`: the
  bespoke name carries the extra duplicates/failed breakdown the spec metric
  lacks (loose alignment).
- **`keiro.inbox.duplicates`** — unit `{message}`, **Counter** (`Int64`).
  Recorded when an inbound message is skipped as a duplicate
  (`recordInboxDuplicates`). Description: "Inbox messages skipped as
  duplicates." Semconv alignment: none.
- **`keiro.inbox.failed`** — unit `{message}`, **Counter** (`Int64`). Recorded
  when a message handler fails (`recordInboxFailed`). Description: "Inbox
  messages whose handler failed." Semconv alignment: none.
- **`keiro.inbox.backlog`** — unit `{message}`, **Gauge** (`Int64`). Recorded by
  the inbox runner each poll pass (`recordInboxBacklog`). Description: "Inbox
  messages awaiting processing." Semconv alignment: none (queue depth).

### Timer

- **`keiro.timer.backlog`** — unit `{timer}`, **Gauge** (`Int64`). Recorded by
  the timer worker each poll pass (`recordTimerBacklog`) with the count of due
  timers awaiting firing. Description: "Due timers awaiting firing." Semconv
  alignment: none.
- **`keiro.timer.fire.lag`** — unit `ms`, **Histogram** (`Double`). Recorded on
  fire (`recordTimerFireLag`) with the delay between a timer's scheduled time
  and when it fired. Description: "Delay between a timer's scheduled time and
  when it fired." Semconv alignment: `$metric_messaging_process_duration`
  (line 3404, `messaging.process.duration`) is not a direct match (keiro's
  histogram is timer-specific, not consumer-processing time) but is the spec's
  precedent for a messaging histogram.
- **`keiro.timer.attempts`** — unit `{attempt}`, **Histogram** (`Double`).
  Recorded on fire (`recordTimerAttempts`) with the number of attempts a timer
  took to fire. Description: "Number of attempts a timer took to fire." Semconv
  alignment: none.
- **`keiro.timer.stuck`** — unit `{timer}`, **Gauge** (`Int64`). Recorded by the
  timer worker each poll pass (`recordTimerStuck`), counting rows stuck in the
  `Firing` state past the threshold defined by EP-34's `findStuckTimers`.
  Description: "Timers stuck in the Firing state past threshold." Semconv
  alignment: none. (Wired after EP-34 lands; see
  `docs/plans/34-add-timer-stuck-row-recovery-and-cancellation-api.md`.)

### Projection

- **`keiro.projection.lag`** — unit `{event}`, **Gauge** (`Int64`). Recorded by
  the async projection drain each pass (`recordProjectionLag`) with the number
  of events between the log head and the projection's checkpoint. Description:
  "Events between the log head and a projection's checkpoint." Semconv
  alignment: none.
- **`keiro.projection.wait.timeouts`** — unit `{timeout}`, **Counter** (`Int64`).
  Recorded on the position-wait path when a read gives up before the projection
  catches up (`recordProjectionWaitTimeouts`). Description: "Position-wait calls
  that timed out before the projection caught up." Semconv alignment: none.

### Command and snapshot

- **`keiro.snapshot.apply.divergence`** — unit `{failure}`, **Counter**
  (`Int64`). Recorded by both command append paths
  (`recordSnapshotApplyDivergence`) when `applyEventsEither` cannot replay a
  just-committed event batch from the pre-command state. Description:
  "Just-appended event batches that failed to replay from the pre-command
  state; the stream is poisoned and its next hydration will fail." Semconv
  alignment: none (event-sourcing replay correctness has no OpenTelemetry
  semantic-convention equivalent).

### Workflow

Added by `docs/plans/44-workflow-observability-spans-and-metrics.md` (EP-44).
The step counters are recorded inside the EP-38 workflow handler; the active
gauge and journal-length histogram are recorded by `runWorkflowWith`; the
resumed counter and pending-awakeables gauge are recorded by the EP-42 resume
worker (`resumeWorkflowsOnce`). All ride on the `Maybe KeiroMetrics` threaded
through `WorkflowRunOptions`, so they no-op under the default (no-metrics)
options.

- **`keiro.workflow.steps.executed`** — unit `{step}`, **Counter** (`Int64`).
  Recorded by the workflow handler on a step *miss* (the action ran and was
  journaled) (`recordWorkflowStepExecuted`). Description: "Workflow steps that
  ran their action (a journal miss)." Semconv alignment: none
  (durable-execution-specific).
- **`keiro.workflow.steps.replayed`** — unit `{step}`, **Counter** (`Int64`).
  Recorded by the workflow handler on a step *hit* (the recorded result was
  returned without running the action; also on an `awaitStep` hit)
  (`recordWorkflowStepReplayed`). Description: "Workflow steps short-circuited to
  a recorded result (a journal hit)." Semconv alignment: none.
- **`keiro.workflow.resumed`** — unit `{workflow}`, **Counter** (`Int64`).
  Recorded by the resume worker once per re-invocation of a discovered
  unfinished workflow (`recordWorkflowResumed`). Description: "Workflow
  re-invocations performed by the resume worker." Semconv alignment: none.
- **`keiro.workflow.active`** — unit `{workflow}`, **Gauge** (`Int64`). Recorded
  by the workflow handler on run entry and exit with the process-wide live-run
  count (`recordWorkflowActive`). Description: "Workflow runs currently in
  progress in this process." Semconv alignment: none (level gauge, like the
  backlog gauges).
- **`keiro.workflow.journal.length`** — unit `{event}`, **Histogram**
  (`Double`). Recorded by the workflow handler once per completion with the
  journal event count (`recordWorkflowJournalLength`). Description: "Journal
  event count of a workflow at completion." Semconv alignment: none
  (distribution, like `keiro.timer.fire.lag`).
- **`keiro.workflow.awakeables.pending`** — unit `{awakeable}`, **Gauge**
  (`Int64`). Recorded by the resume worker each poll pass from
  `countPendingAwakeables` (`recordWorkflowAwakeablesPending`). Description:
  "Awakeables awaiting an external signal." Semconv alignment: none (queue
  depth).

### Metrics compliance table

| Instrument                       | Unit       | Kind      | Recording site (EP-35/EP-36)              | Semconv alignment                                   |
| -------------------------------- | ---------- | --------- | ----------------------------------------- | --------------------------------------------------- |
| keiro.outbox.backlog             | {event}    | Gauge     | outbox publisher, per poll pass           | none (queue-depth; no messaging-metric equivalent)  |
| keiro.outbox.published           | {event}    | Counter   | outbox publisher, on publish success      | $metric_messaging_client_sent_messages 3407 (loose) |
| keiro.outbox.retried             | {event}    | Counter   | outbox publisher, on transient failure    | none                                                |
| keiro.outbox.deadlettered        | {event}    | Counter   | outbox publisher, on retry exhaustion     | none                                                |
| keiro.inbox.processed            | {message}  | Counter   | inbox runner, on handler success          | $metric_messaging_client_consumed_messages 3410     |
| keiro.inbox.duplicates           | {message}  | Counter   | inbox runner, on duplicate skip           | none                                                |
| keiro.inbox.failed               | {message}  | Counter   | inbox runner, on handler failure          | none                                                |
| keiro.inbox.backlog              | {message}  | Gauge     | inbox runner, per poll pass               | none (queue-depth)                                  |
| keiro.timer.backlog              | {timer}    | Gauge     | timer worker, per poll pass               | none                                                |
| keiro.timer.fire.lag             | ms         | Histogram | timer worker, on fire                     | $metric_messaging_process_duration 3404 (precedent) |
| keiro.timer.attempts             | {attempt}  | Histogram | timer worker, on fire                     | none                                                |
| keiro.timer.stuck                | {timer}    | Gauge     | timer worker, per poll pass (after EP-34) | none                                                |
| keiro.projection.lag             | {event}    | Gauge     | async projection drain, per pass          | none                                                |
| keiro.projection.wait.timeouts   | {timeout}  | Counter   | position-wait path, on timeout            | none                                                |
| keiro.snapshot.apply.divergence  | {failure}  | Counter   | command epilogue, on replay divergence    | none                                                |
| keiro.workflow.steps.executed    | {step}     | Counter   | workflow handler, on step miss            | none                                                |
| keiro.workflow.steps.replayed    | {step}     | Counter   | workflow handler, on step hit             | none                                                |
| keiro.workflow.resumed           | {workflow} | Counter   | resume worker, per re-invocation          | none                                                |
| keiro.workflow.active            | {workflow} | Gauge     | workflow handler, on run entry/exit       | none (level)                                        |
| keiro.workflow.journal.length    | {event}    | Histogram | workflow handler, on completion           | none (distribution)                                 |
| keiro.workflow.awakeables.pending| {awakeable}| Gauge     | resume worker, per poll pass              | none (queue depth)                                  |


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
- **Metrics audit** — see the `## Metrics` section above (added by
  `docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`).
- **Log / exception audit** — separate from this plan.
