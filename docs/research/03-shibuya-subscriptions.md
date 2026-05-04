# Shibuya Subscription Engine — Current State Survey

Survey author: research subagent (Explore), 2026-05-04. Source trees:

- `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` (core, example, metrics, bench)
- `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`
- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter`

## Overview

Shibuya is a supervised queue-processing framework for Haskell inspired by Elixir's Broadway. It provides a unified abstraction over heterogeneous message queue backends (Kafka, PostgreSQL pgmq, SQS, Redis) with built-in NQE supervision, Streamly-based backpressure, and OpenTelemetry distributed tracing. The framework decouples queue-specific concerns (adapters) from the core processing engine, allowing write-once-run-anywhere handlers.

Core principle: **separation of concerns** — Streamly handles I/O and backpressure; NQE handles supervision; adapters own queue semantics; handlers express *intent*, not mechanics.

## Core Abstractions

Core types (`Shibuya/Core/Types.hs`):

- `MessageId` (Text) — stable identity for idempotency & observability
- `Cursor` (Int or Text) — optional position/offset for ordered streams
- `Attempt` (Word) — zero-indexed delivery counter (0 = first delivery, 1 = first retry)
- `Envelope msg` — normalized message container with metadata (`messageId`, `cursor`, `partition`, `enqueuedAt`, `traceContext`, `attempt`, `payload`)
- `TraceHeaders` — W3C trace context

Handler (`Shibuya/Handler.hs:15`):

    type Handler es msg = Ingested es msg -> Eff es AckDecision

Handlers receive `Ingested`, which wraps:

- `envelope :: Envelope msg` — metadata + payload
- `ack :: AckHandle es` — mechanical finalization callback
- `lease :: Maybe (Lease es)` — optional visibility-timeout extension

Ack semantics (`Shibuya/Core/Ack.hs`):

- `AckOk` — success; commit the message.
- `AckRetry RetryDelay` — retry after delay (exponential backoff optional).
- `AckDeadLetter DeadLetterReason` — route to DLQ (`PoisonPill`, `InvalidPayload`, `MaxRetriesExceeded`).
- `AckHalt HaltReason` — stop processing (`HaltOrderedStream`, `HaltFatal`).

Adapter interface (`Shibuya/Adapter.hs:16-23`):

    data Adapter es msg = Adapter
      { adapterName :: !Text
      , source :: Stream (Eff es) (Ingested es msg)  -- Pull-based source
      , shutdown :: Eff es ()
      }

**Subscription model**: adapters expose pull-based streams (Streamly), not push-based subscriptions. The ingester pulls and applies backpressure via a bounded inbox.

## Adapter Pattern

Separation:

1. **Ingester** (`Shibuya/Runner/Ingester.hs:28-35`) — pulls from `adapter.source`, sends to bounded inbox. Backpressure via blocking `send`.
2. **Processor** (`Shibuya/Runner/Processor.hs:19-26`) — receives from inbox, calls handler, finalizes ack.
3. **Adapter** — converts queue-specific operations into `Stream (Eff es) (Ingested es msg)`.

### shibuya-kiroku-adapter

`kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:122-147`.

- Wraps Kiroku's push-based subscription into pull via bounded `TBQueue` bridge.
- `subscriptionStream` (from kiroku-store) handles internal push→queue→stream conversion.
- Lifts `Stream IO` to `Stream (Eff es)` via `Stream.morphInner liftIO`.
- **Ack semantics** — AckOk/Retry/DeadLetter are no-ops (Kiroku manages checkpoint internally); only AckHalt cancels the subscription.
- **Cursor** — maps event's `globalPosition` → `CursorInt`; no `attempt` field (events are immutable).

### shibuya-pgmq-adapter

`shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs:1-75`.

- Uses pgmq-hs client for pull-based queries (`readMessage`, `readGrouped`).
- Visibility timeout (`visibilityTimeout` in config, extends on AckRetry/AckHalt).
- **Cursor** — pgmq message ID (Int64) → `CursorInt`.
- **Attempt** — extracts pgmq's `readCount` (1-based) → 0-based `Attempt`.
- Dead-letter — routes to separate DLQ queue or archives the message.
- Prefetch (`PrefetchConfig`) for batched reads.
- FIFO support — groups via `x-pgmq-group` header; reads via `readGrouped` or `readGroupedRoundRobin`.

## Checkpointing & Cursors

Per-adapter responsibility; framework-agnostic.

PGMQ (`Shibuya/Adapter/Pgmq/Internal.hs:93-112`):

- No explicit checkpoint in Shibuya core.
- pgmq's `readMessage` implicitly advances by deleting messages on finalization.
- Visibility timeout extended on AckRetry/AckHalt via `changeVisibilityTimeout`.
- `attempt` populated from `msg.readCount`.

Kiroku (`Shibuya/Adapter/Kiroku/Convert.hs:49-59`):

- Checkpoint managed entirely by Kiroku subscription worker (external to handler).
- Handler ack does NOT influence checkpoint (no ack payload).
- Only AckHalt cancels the subscription; other decisions are no-ops.
- Checkpoint advances automatically as handler returns successfully.

## Concurrency & Ordering

Policies (`Shibuya/Policy.hs:19-44`):

    data Ordering = StrictInOrder | PartitionedInOrder | Unordered
    data Concurrency = Serial | Ahead Int | Async Int
    -- StrictInOrder must be Serial; validated at runApp time.

Serial (`Shibuya/Runner/Serial.hs:26-45`): processes each message sequentially via `Stream.fold Fold.drain`. No inbox buffering.

Supervised runner (`Shibuya/Runner/Supervised.hs:132-150`): bounded inbox, ingester and processor concurrent (non-blocking each other). Concurrency modes:

- `Serial` — inbox size 1, one handler instance.
- `Ahead n` — inbox size n, prefetch but process serially (preserves ordering).
- `Async n` — inbox size n, n handler tasks in parallel (no ordering).

**Ordering guarantee**: only `Serial + StrictInOrder` guarantees strict ordering. Partition-level ordering requires idempotent handlers.

## Failure Semantics

Retry (`Shibuya/Core/Retry.hs:1-120`):

- Handler returns `AckRetry RetryDelay` or calls `retryWithBackoff (BackoffPolicy) (Envelope)`.
- `BackoffPolicy` — base delay, factor (growth), `maxDelay`, jitter (`NoJitter`, `FullJitter`, `EqualJitter`).
- `defaultBackoffPolicy` — 1s base, factor 2, max 5min, FullJitter.
- Pure: `exponentialBackoffPure policy (Attempt n) jitterSample`. Effectful: `exponentialBackoff policy attempt`.

Dead-letter:

- `AckDeadLetter (PoisonPill | InvalidPayload | MaxRetriesExceeded)`.
- PGMQ — routes to configured DLQ queue or archives.
- Kiroku — no-op (events are immutable).

Halt: `AckHalt (HaltOrderedStream | HaltFatal)` stops processor; supervisor applies strategy.

Idempotency: framework guarantees at-least-once. Handlers must be idempotent. Message ID available for dedup. PGMQ's `readCount` and lease extension allow optimization.

Poison messages: max retries per pgmq config, then auto-DLQ before handler sees them.

## Lifecycle & Supervision

Entry point (`Shibuya/App.hs:146+`):

    runApp :: SupervisionStrategy -> Int
           -> [(ProcessorId, QueueProcessor es)]
           -> Eff es (Either AppError (AppHandle es))

Supervision: `IgnoreFailures` (failed processor marked Failed, others continue) or `StopAllOnFailure`.

Process tree (`Shibuya/Runner/Master.hs:98-117`):

1. Master process starts NQE Supervisor.
2. For each processor: `addChild supervisor (runSupervised master ...)`.
3. Each supervised processor registers metrics TVar.
4. Ingester and processor run concurrently under Master's supervision.

Graceful shutdown (`Shibuya/App.hs:94-104`):

    data ShutdownConfig = ShutdownConfig { drainTimeout :: NominalDiffTime }
    defaultShutdownConfig = ShutdownConfig { drainTimeout = 30 }

`stopAppGracefully` waits for in-flight messages, then forcefully kills after timeout.

## Effectful Surface

- `IOE` — required.
- `Tracing` — optional; `runTracing tracer` or `runTracingNoop` (zero overhead).
- Handler `Eff es` can include any effect (e.g., `Hasql :> es`, `Pgmq :> es`).

Composition with keiro: keiro provides effects for decide/emit; shibuya provides ingestion. PGMQ adapter allows composing within the same transaction (`Pgmq :> es` for both source and side effects), but durability requires an outbox.

## Observability & Metrics

Metrics (`Shibuya/Runner/Metrics.hs:4-28`):

    data ProcessorState = Idle | Processing InFlightInfo UTCTime | Failed Text UTCTime | Stopped
    data StreamStats = StreamStats { received, dropped, processed, failed :: !Int }
    data ProcessorMetrics = ProcessorMetrics { state, stats, startedAt, ... }

Introspection: `getAppMetrics` (snapshot of all processors); `getProcessorMetrics` (single).

OpenTelemetry tracing (`Shibuya/Telemetry/Effect.hs`): per-message span (kind Consumer); attributes include `messaging.system`, `messaging.operation`, `messaging.message.id`, `shibuya.partition`, `shibuya.inflight.count/max`, `shibuya.ack.decision`. Events: `shibuya.handler.started`, `shibuya.handler.completed`, `shibuya.ack.decision`, `exception`. W3C traceparent propagation.

Metrics server (`shibuya-metrics`): HTTP `/json`, `/metrics` (Prometheus), WebSocket streaming. Subscribe to all processors or specific `ProcessorIds`.

## Key Files for Integration

- `shibuya-project/shibuya/shibuya-core/src/Shibuya/Adapter.hs:14-23` — Adapter interface
- `shibuya-project/shibuya/shibuya-core/src/Shibuya/Handler.hs:14-15` — Handler type
- `shibuya-project/shibuya/shibuya-core/src/Shibuya/Core/Ack.hs:44-54` — Ack semantics
- `kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:122-147` — Kiroku integration
- `shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs:71-150` — PGMQ integration

## Gaps for Keiro

### Top 5 most consequential gaps

1. **Transactional checkpoint + side effect (exactly-once outbox).** No single-transaction coupling of checkpoint advancement and downstream event emission. Keiro needs "emit events + advance subscription checkpoint" in the same DB transaction.
2. **Process manager primitive.** No `(event, state) → decision(s)` abstraction with multi-emit support. Handlers are 1→1; process managers are N→M.
3. **Durable timer / scheduled-event generation.** No built-in way to emit "wake up" events after a delay without external orchestration. Keiro's timeout saga step needs this.
4. **Aggregate snapshot / version load optimization.** Kiroku adapter streams all events unconditionally. Keiro needs "load aggregate to version N" for efficient state rebuild before processing (especially for long-lived sagas).
5. **Multi-source correlation & fan-out.** No native support for joining events from 2+ streams. Keiro's distributed workflow steps often depend on multiple event streams.

### Additional gaps

- Filtering & category-level subscriptions only via Kiroku adapter; PGMQ adapter is queue-level only; no event-type pattern matching in core.
- No consumer-group / sharded processing across multiple framework instances.
- Lease extension can only extend, not proactively release on `AckDeadLetter`.
- No built-in handler composition / middleware (logging, tracing, retry decoration) beyond what Effect-stack composition gives.

### Strengths to leverage

- Clean handler interface (`Ingested → Eff es AckDecision`).
- Backpressure by default via bounded inbox.
- Flexible concurrency (Serial/Ahead/Async) for different ordering constraints.
- OpenTelemetry built-in.
- Modular adapter pattern: keiro can ship its own adapter wrapping Kiroku + PGMQ together.
- NQE supervision: failed processors do not crash the app.
