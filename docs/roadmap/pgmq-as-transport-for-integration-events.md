---
slug: pgmq-as-transport-for-integration-events
title: "PGMQ as a transport for integration events (case B)"
kind: roadmap
status: not-scheduled
created_at: 2026-06-07T17:25:21Z
origin: "docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md"
---

# PGMQ as a transport for integration events (case B)

> **Status: ROADMAP — not scheduled.** This is a captured future-enhancement design, not a
> commitment. It was promoted out of MasterPlan 7
> (`docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md`), whose built scope (the
> `keiro-pgmq` package + the rei and hospital-capacity migrations) is complete, so that the
> case-B design lives somewhere discoverable rather than as a dangling deferred child plan.
> **To schedule it:** record the decision in MasterPlan 7's Decision Log, then create a proper
> self-contained ExecPlan in `docs/plans/` (using the exec-plan skill) from the sketch below.

This document exists to (a) preserve the case-B design and (b) pin down the one integration
constraint that keeps it cheap to build later.


## The idea

The `keiro-pgmq` package (MasterPlan 7) was built for **case A**: transient background jobs
that are *not* domain events. **Case B** is a deliberately deferred future enhancement: using
PostgreSQL's message queue (PGMQ) as a **delivery transport for domain integration events**,
so teams that do not want to adopt Kafka can still exchange events across bounded contexts.
PGMQ supports topics / fan-out (one publish reaching many subscribers), which is the feature
that makes it a viable Kafka alternative for this purpose.

"Integration event" means a domain fact published from one bounded context for others to
consume (as opposed to an internal background job). keiro already has seams for these:
`Keiro.Inbox` (idempotent intake of inbound integration events, today with Kafka transport
codecs in `Keiro.Inbox.Kafka`) and `Keiro.Outbox` (durable handoff of outbound integration
events, today with `Keiro.Outbox.Kafka` codecs). The keiro design deliberately keeps the
actual Kafka driver (`hw-kafka-client`) out of the framework and ships only pure transport
codecs; the real driver is wired by the application/test layer.

Case B follows that exact pattern but for PGMQ: add `Keiro.Inbox.Pgmq` and `Keiro.Outbox.Pgmq`
transport codecs/wiring that sit beside the Kafka ones, reusing the PGMQ plumbing that
`keiro-pgmq` already factored out.

What someone gains when this is eventually built: a keiro application can publish and consume
cross-context integration events over PGMQ (with topic fan-out for multiple subscribers)
instead of Kafka, configured under the same `Keiro.Inbox`/`Keiro.Outbox` seams they already
use — no Kafka broker required.


## The hard design constraint (the reason this stays cheap)

Case B must build on the **Runtime layer** of `keiro-pgmq` (`Keiro.PGMQ.Runtime`: queue-name
derivation via `QueueRef`, the `Pgmq : Tracing : Error PgmqRuntimeError : IOE` runner, and the
pool/tracer lifecycle — `JobRuntime` / `withJobRuntime` / `runJobEff`) and **must not** depend
on the case-A `Job` layer (`Keiro.PGMQ.Job`). A `Job` is a background-work abstraction;
integration-event transport is a different concern that should not inherit the
`Job`/`JobOutcome` ergonomics.

This is recorded as **Integration Point 2** in MasterPlan 7. MasterPlan 7's EP-1 outcome
confirmed the two layers landed cleanly separable. If, when this is scheduled, the Runtime
layer has accreted Job-specific concerns, the first task is to re-separate them before adding
the Inbox/Outbox transports.


## Context a future implementer needs

Relevant existing seams in the keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro`:

- `keiro/src/Keiro/Inbox.hs` and `keiro/src/Keiro/Inbox/Kafka.hs` — the inbox: idempotent
  intake of inbound integration events, deduped by message/source identity. The `.Kafka`
  module is a pure codec (`integrationEventFromKafka` reconstructs an `IntegrationEvent` from
  Kafka headers + payload) with no `hw-kafka-client` dependency in the framework.
- `keiro/src/Keiro/Outbox.hs` and `keiro/src/Keiro/Outbox/Kafka.hs` — the outbox: durable
  handoff of outbound integration events with ordering policies. The `.Kafka` module is a pure
  codec (`outboxRowToKafkaRecord`).
- `keiro-core/src/Keiro/Integration/Event.hs` — the `IntegrationEvent` envelope contracts
  shared by inbox/outbox.

The `keiro-pgmq` package provides, in its Runtime layer (`Keiro.PGMQ.Runtime`): `QueueRef`
(logical→physical+DLQ name derivation), `JobRuntime`, `withJobRuntime`, and `runJobEff` (the
`Pgmq : Tracing : Error PgmqRuntimeError : IOE` runner). Case B reuses these and must **not**
import `Keiro.PGMQ.Job`.

PGMQ topic / fan-out facts (for the publish-to-many requirement): the PGMQ client exposes
topic operations (`bindTopic`, `sendTopic`, `listTopicBindings`) in pgmq ≥ 1.11, and
`shibuya-pgmq-adapter` already models a `TopicRoute`/`topicDeadLetter` target. A single
`sendTopic` publish can fan out to all queues bound to a routing key — this is the mechanism
that lets one outbound integration event reach multiple subscribing contexts. On-disk source:
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` and
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.


## Sketch of the eventual work

When scheduled, this becomes a self-contained ExecPlan with these milestones:

1. **Outbox over PGMQ** — `Keiro.Outbox.Pgmq`: a codec/wiring that turns an outbox row into a
   PGMQ topic publish (`sendTopic` with a routing key), reusing `Keiro.PGMQ.Runtime` for the
   connection/effect stack. Verify one publish fans out to multiple bound subscriber queues.
2. **Inbox over PGMQ** — `Keiro.Inbox.Pgmq`: consume from a subscriber queue (bound to the
   topic) and reconstruct an `IntegrationEvent` for the idempotent inbox, again on
   `Keiro.PGMQ.Runtime`.
3. **Topic/binding management** — idempotent setup of topics and per-subscriber bindings (the
   integration-event analogue of `ensureJobQueue`).
4. **A proving-ground migration** — point one cross-context link in `keiro-runtime-jitsurei`
   (which currently connects bounded contexts with Kafka + PGMQ work queues) at the PGMQ
   integration-event transport, demonstrating Kafka-free cross-context delivery.


## Acceptance (when built)

A domain integration event published from one bounded context over PGMQ is received by two or
more subscribing contexts (proving fan-out), configured under `Keiro.Outbox`/`Keiro.Inbox`,
with no Kafka broker in the loop — verified by an end-to-end scenario in a proving-ground app.

Idempotence constraints when built: topic/binding setup must be idempotent (like
`ensureJobQueue`); inbox intake must remain idempotent by integration-event identity (the
existing inbox dedup contract).


## Rationale for keeping this on the roadmap

The immediate need was case A; case B is a real future option for Kafka-averse teams and must
not be lost. Capturing it now also pins the integration constraint (build on
`Keiro.PGMQ.Runtime`, not `Keiro.PGMQ.Job`) while that boundary is fresh. When built, case B
lives as `Keiro.Inbox.Pgmq` / `Keiro.Outbox.Pgmq` transport codecs/wiring — siblings of the
existing `Keiro.Inbox.Kafka` / `Keiro.Outbox.Kafka` — so PGMQ becomes one more transport
rather than a new abstraction, mirroring keiro's "pure transport codecs, driver wired outside
the framework" pattern.

---

*History: originally captured as MasterPlan 7's deferred child ExecPlan
`docs/plans/58-deferred-pgmq-as-transport-for-integration-events-case-b.md` (id 58); promoted
to this roadmap doc on 2026-06-07 once MasterPlan 7's built scope (EP-1, EP-2, EP-3) was
complete, so the case-B design is easy to find independently of the closed initiative.*
