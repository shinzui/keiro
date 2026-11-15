---
type: Research Document
title: OpenTelemetry semantic-conventions audit
description: Audit Keiro instrumentation sites against the OpenTelemetry semantic conventions and record gaps and actions.
timestamp: 2026-11-15T01:15:00Z
researchId: RES-16
status: active
scope: Keiro tracing and metrics instrumentation governed by OpenTelemetry semantic conventions.
---

# OpenTelemetry semantic-conventions audit

This document audits every place in the `keiro` library where OpenTelemetry
instrumentation should exist according to the **OpenTelemetry semantic
conventions**, and records what is currently emitted versus what the spec
requires. Each per-site section names the file and call site, the span name
and kind, the required, conditionally required, and recommended attributes
(citing the Haskell `AttributeKey` identifier exported from
`OpenTelemetry.SemanticConventions`), the spec section anchor in the
generated module, and a gap-vs.-action line.

The Haskell binding is owned by
`mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-semantic-conventions`, at
project-relative `hs-opentelemetry/semantic-conventions/src/OpenTelemetry/SemanticConventions.hs`
(the source-artifact URI is pending).

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

`Keiro.Outbox.enqueueProducerEventTx` runs in the caller's SQL transaction and
opens no independent span. `IntegrationProducer.tracePolicy` defaults explicitly
to `PreserveDraftTrace` in examples and fixtures. With `DeriveTraceAfter cutoff`,
only source events strictly above the immutable recorded global-position cutoff
derive missing creation context from stored metadata. Explicit draft context wins;
overridden draft provenance does not change eligibility. This is independent of a
tracer on the enqueuing worker. Legacy, pre-cutover and explicit-context paths do
not read source metadata. The frozen producer digest still includes `TraceField`.

The inline `enqueueIntegrationEventTx` path has no source event. Applications
capture context before the transaction and preserve the same value on replay.
See [producer adoption](../user/outbox.md#trace-policy-adoption) and
[ADR-60](../adr/0060-event-creation-context-and-durable-span-correlation.md).

## Outbox publish

`Keiro.Outbox.publishClaimedOutbox` uses `Keiro.Telemetry.withProducerBatchSpan`.
The Producer-kind span is a root, restoring any ambient context on exit. It is
named `send <destination>` for a uniform batch and `send` for a mixed batch.

The span records `messaging.system=kafka`, `messaging.operation.name=send`,
`messaging.operation.type=publish`, `messaging.batch.message_count` and the
existing `keiro.outbox.batch.size`. Only uniform batches have the span's
`messaging.destination.name`. Only singleton batches have `messaging.message.id`
and the Kafka key on the span.

Each valid stored creation context contributes a link with `messaging.message.id`,
up to 128 links in row order. Mixed batches additionally put the destination on
each link. Further valid contexts are counted in `keiro.outbox.links.dropped`.
Absent or malformed contexts omit links. Evaluated link identities and scalar
attributes own no outbox row or payload. A missing tracer bypasses batch decoding.

Wire headers retain the stored creation context; they never take the send span's
identity. `PublishFailed` sets `error.type=publish_failed` and error status.
`PublishRejected` is a handled terminal decision and leaves error status unset.
The exported single-message `withProducerSpan` retains its existing API for
application callers; the durable publisher uses the batch-aware helper.


## Inbox consume

Kafka decoding in `Keiro.Inbox.Kafka.integrationEventFromKafka` is pure. The inbox
opens no independent span. Applications consuming records without Shibuya can call
`Keiro.Telemetry.withConsumerSpan` around decode/handling: it opens a Consumer span
named `process <topic>`, parented under and linked to the W3C creation context.
Absent or malformed context inherits the ambient context without links.

Attributes describe Kafka, the process operation, topic, partition, offset, optional
key/group and decoded message ID. Scalar projections are evaluated before SDK
ownership. The application owns decode-failure classification and handler outcomes;
the helper does not claim a decoder or inbox runner emitted spans automatically.

## Inbox process

Both transaction and delegated inbox modes execute the handler synchronously inside
the caller's transport processing span. Business child spans are application-owned.
No deferred boundary or independent inbox span is introduced.

## Subscription workers

All six process-manager, router and reaction worker entry points wrap each delivery
in one `process <worker name>` Consumer span through Shibuya's shared IO helper.
They reuse `RunCommandOptions.tracer`. Policy and span name are shared once per
worker; without a tracer the original handler is selected and envelope telemetry
is untouched.

A valid envelope creation context contributes one link. The adapter's
`telemetry.traceCorrelation` chooses `ParentAndLink` or `LinkOnly`; the Kiroku adapter
defaults to `LinkOnly`. With no usable context the shared helper retains its
ambient-parent fallback. The span records `messaging.system=keiro`, destination,
operation name/type `process`, message ID and adapter attributes (including Kiroku's
subscription/event attributes). Primitive attribute values are evaluated before
handoff so lazy projections cannot retain envelopes or payloads.

Dispatch and acknowledgement finalization stay inside the span. Dispatched commands
are children and stamp their own appended events. Every settled decision records the
existing `shibuya.ack.decision` vocabulary. `AckOk` includes duplicates and handled
skips; retry, dead-letter and halt decisions mark this delivery as an error using
only the decision classifier. Business reason text is not retained. A thrown exception
is recorded by the span scope and does not fabricate an acknowledgement.

The real Kiroku chain test verifies command creation metadata, a linked processing
root, its child target command and that command's persisted creation metadata.


## Command run

**Files:**

- `src/Keiro/Command.hs:250` — `runCommand`.
- `src/Keiro/Command.hs:286` — `runCommandWithSql`.
- `src/Keiro/Command.hs:298` — `runCommandWithSqlEvents`.

**Span name:** `command <category>`, using Kiroku's canonical prefix-before-dash rule.
A command targeting `counter-7` produces `command counter`; the full name remains an attribute.

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

**Implemented (2026-11-14):** All four plain/domain and transactional entry points use
`Keiro.Telemetry.withCommandSpan`. With a configured tracer, shared metadata stamping captures
this span once before the retry loop and stamps every event in the accepted batch. Caller
`traceparent` takes precedence, and non-object metadata retains the codec's validation error.
With no configured tracer, the original metadata passes through without a context read.
Creation metadata changes neither domain replay nor deterministic identifiers; producer
adoption remains governed by ADR-59's immutable cutover.

> **Follow-up:** Once `hasql-opentelemetry` is wired into `kiroku-store`,
> the actual per-statement database spans appear as children of the
> command span. That work is tracked under
> `mori://shinzui/hasql-opentelemetry` and explicitly out
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

**File:** `keiro/src/Keiro/Timer.hs` — `claimAndFireOne`.

**Span name:** `timer fire <processManagerName>`; **kind:** `Internal`.

With `TimerWorkerOptions.tracer`, each firing opens a root span with the stored
creation context as a link. It covers the fire action and mark-fired write. Commands
called by the fire action are children and stamp their own event contexts. Attributes:
`keiro.timer.id`, `keiro.timer.process_manager`, and `keiro.timer.fire_lag` (milliseconds).
Exceptions use the SDK's error status; retry and dead-letter behavior stays unchanged.

`TimerRequest.traceContext` is stored in nullable `traceparent`/`tracestate` columns.
Capture occurs before SQL, only with explicit tracing enablement, and preserves a supplied
request context. Legacy/null or malformed context yields an unlinked root. No configured
worker tracer bypasses span creation and context decoding.


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

**Implemented:** `WorkflowRunOptions.tracer` opens a root span per invocation and
stamps journal metadata before transaction preparation. Sleep, signal and child wake
paths use explicitly traced APIs; legacy wrappers remain untraced.

At entry, one generation-qualified hint query selects an indexed first-event reference;
two normal event reads recover journal origin and exact awaited wake contexts independently
of snapshots. Link attributes use `keiro.workflow.link = origin | wake`; equal identities
prefer `wake`. The lateral reference lookup limits before joining event payloads, avoiding
a full-journal sort in the generic forward-read query. Read hooks remain active. Invalid,
missing, foreign-stream or mismatched-step evidence omits the unavailable link. Links are
added after opening the span, so head samplers cannot consider them. Ambient context is
restored on success, failure and cancellation. No per-step spans are added by this work.


## Compliance table

This table summarizes implemented tracing and remaining historical instrumentation gaps.

| Site                | Span name pattern              | Kind     | Anchor                                       | Current status |
| ------------------- | ------------------------------ | -------- | -------------------------------------------- | ----------------------- |
| Outbox enqueue      | `create <destination>`         | Internal | `$attributes_messaging_trace_minimal` 27014  | Durable context; no independent span |
| Outbox publish      | `send <destination>` or `send` | Producer | `$attributes_messaging_trace_minimal` 27014  | Root with bounded creation links |
| Inbox consume       | `process <destination>`        | Consumer | `$attributes_messaging_trace_minimal` 27014  | Exported parent-and-link helper |
| Inbox process       | (inherits consumer span)       | Internal | n/a                                          | Inherits transport span |
| Subscription workers | `process <worker>` | Consumer | shared Shibuya process helper | Adapter policy and creation link |
| Command run         | `command <category>`                     | Internal | `$span_db_client` 19833                      | Category span with creation metadata |
| Hydration           | `hydrate <stream>`             | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Snapshot read/write | `snapshot.{read,write} <s>`    | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Read-model rebuild  | `rebuild <read-model>`         | Internal | `$span_db_client` 19833                      | Gap (follow-up)         |
| Projection apply    | `apply <projection>`           | Internal | n/a (bespoke)                                | Gap (follow-up)         |
| Timer fire          | `timer fire <manager>`        | Internal | root with stored creation link              | Implemented            |
| Workflow run        | `workflow <name>`              | Internal | root with bounded origin/exact-wake links    | Implemented            |


## Metrics

This section catalogues the metric instruments keiro records. They are
defined in `keiro/src/Keiro/Telemetry.hs` by
`docs/plans/33-add-an-opentelemetry-metrics-surface-to-keiro-telemetry.md`
(EP-33) as the `KeiroMetrics` record built by `newKeiroMetrics`, and recorded
through the `record*` helpers at the worker call sites added by EP-35 (outbox +
inbox) and EP-36 (timer + projection). The six `keiro.workflow.*` instruments
were added by EP-44 (workflow observability) and are recorded by the v2 workflow
runtime and resume worker. The names, units, kinds, and description strings
below match `newKeiroMetrics` character-for-character; EP-35/EP-36/EP-37/EP-44
reference them verbatim.

The instrument **kind** policy: backlog and position-distance values are synchronous gauges recorded
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
- **`keiro.outbox.rejected`** — unit `{event}`, **Counter** (`Int64`). Recorded
  when a publisher's intentional permanent refusal commits as terminal
  `rejected` (`recordOutboxRejected`). Description: "Outbox events permanently
  rejected by the publisher." It carries no rejection-code or detail attributes.
  Semconv alignment: none.
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

- **`keiro.projection.global_position_distance`** — unit `{position}`, **Gauge**
  (`Int64`). Recorded by the async projection drain each pass
  (`recordProjectionGlobalPositionDistance`) from one Kiroku durable inventory:
  the captured global store cursor minus the slowest matching member checkpoint,
  clamped at zero. The value is a cursor distance, not a relevant-event count;
  filtered, category, hard-deleted, and sharded histories can skip positions.
  Description: "Global position distance between the captured store position and
  a projection's slowest durable member checkpoint." Semconv alignment: none.
- **`keiro.projection.lag`** — unit `{position}`, **Gauge** (`Int64`). Deprecated
  0.11 compatibility instrument recorded from the same snapshot and with the same
  value as `keiro.projection.global_position_distance`. Description: "Deprecated
  compatibility gauge for the global position distance between the captured store
  position and a projection's slowest durable member checkpoint." Semconv
  alignment: none.
- **`keiro.projection.wait.timeouts`** — unit `{timeout}`, **Counter** (`Int64`).
  Recorded on the position-wait path when a read gives up before the projection
  catches up (`recordProjectionWaitTimeouts`). Description: "Position-wait calls
  that timed out before the projection caught up." Semconv alignment: none.
- **`keiro.projection.rebuild.starts`**, **`.resumes`**, **`.pages`**,
  **`.events`**, **`.failures`**, and **`.promotions`** are monotonic `Int64`
  counters recorded by the catalog replay runner at the named lifecycle or
  commit boundary. Units are `{run}`, `{run}`, `{page}`, `{event}`, `{failure}`,
  and `{run}` respectively. **`keiro.projection.rebuild.page.duration`** is a
  millisecond `Double` histogram covering one page read plus its atomic target
  and progress commit. No instrument carries payloads or secrets. Semconv
  alignment: none; fixed-head event-sourcing rebuilds have no standard metric.

### Command and snapshot

- **`keiro.snapshot.apply.divergence`** — unit `{failure}`, **Counter**
  (`Int64`). Recorded by both command append paths
  (`recordSnapshotApplyDivergence`) when `applyEventsEither` cannot replay a
  just-committed event batch from the pre-command state. Description:
  "Just-appended event batches that failed to replay from the pre-command
  state; the stream is poisoned and its next hydration will fail." Semconv
  alignment: none (event-sourcing replay correctness has no OpenTelemetry
  semantic-convention equivalent).
- **`keiro.snapshot.seed.divergence`** — unit `{failure}`, **Counter**
  (`Int64`). Recorded by the sampled snapshot-seed verifier when the canonical
  encoded seed disagrees with a full replay through the seed version.
  Description: "Sampled snapshot seeds whose encoded state disagreed with a
  full replay through the seed version." Semconv alignment: none.

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
| keiro.outbox.rejected            | {event}    | Counter   | outbox publisher, on terminal rejection   | none                                                |
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
| keiro.projection.global_position_distance | {position} | Gauge | async projection drain, per pass      | none                                                |
| keiro.projection.lag             | {position} | Gauge     | async projection drain, compatibility     | none                                                |
| keiro.projection.wait.timeouts   | {timeout}  | Counter   | position-wait path, on timeout            | none                                                |
| keiro.projection.rebuild.starts  | {run}      | Counter   | catalog runner, after durable start       | none                                                |
| keiro.projection.rebuild.resumes | {run}      | Counter   | catalog runner, after accepted resume     | none                                                |
| keiro.projection.rebuild.pages   | {page}     | Counter   | catalog runner, after chunk commit        | none                                                |
| keiro.projection.rebuild.events  | {event}    | Counter   | catalog runner, after chunk commit        | none                                                |
| keiro.projection.rebuild.failures| {failure}  | Counter   | catalog runner, on structured failure     | none                                                |
| keiro.projection.rebuild.promotions| {run}    | Counter   | catalog runner, after atomic promotion    | none                                                |
| keiro.projection.rebuild.page.duration| ms    | Histogram | catalog runner, page read and commit      | none                                                |
| keiro.snapshot.apply.divergence  | {failure}  | Counter   | command epilogue, on replay divergence    | none                                                |
| keiro.snapshot.seed.divergence   | {failure}  | Counter   | sampled hydration verifier, on divergence | none                                                |
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
