---
id: 58
slug: deferred-pgmq-as-transport-for-integration-events-case-b
title: "Deferred pgmq-as-transport for integration events case B"
kind: exec-plan
created_at: 2026-06-07T17:25:21Z
intention: "intention_01kthhpasxesx8hp84264cjhpx"
master_plan: "docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md"
---

# Deferred pgmq-as-transport for integration events case B

> **Status: DEFERRED.** This plan is recorded so the design is not lost. It is **not**
> scheduled or implemented in the current initiative. Do not begin implementation without an
> explicit decision to schedule it (record that decision in the MasterPlan's Decision Log
> first). Its purpose right now is to (a) preserve the case-B design and (b) pin down the
> integration constraint that keeps it cheap later.

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date if and when it is
scheduled.


## Purpose / Big Picture

The current initiative builds `keiro-pgmq` for **case A**: transient background jobs that
are *not* domain events (see
`docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md`). This
plan captures **case B**, a deliberately deferred future enhancement: using PostgreSQL's
message queue (PGMQ) as a **delivery transport for domain integration events**, so teams
that do not want to adopt Kafka can still exchange events across bounded contexts. PGMQ
supports topics / fan-out (one publish reaching many subscribers), which is the feature that
makes it a viable Kafka alternative for this purpose.

"Integration event" means a domain fact published from one bounded context for others to
consume (as opposed to an internal background job). keiro already has seams for these:
`Keiro.Inbox` (idempotent intake of inbound integration events, today with Kafka transport
codecs in `Keiro.Inbox.Kafka`) and `Keiro.Outbox` (durable handoff of outbound integration
events, today with `Keiro.Outbox.Kafka` codecs). The keiro design deliberately keeps the
actual Kafka driver (`hw-kafka-client`) out of the framework and ships only pure transport
codecs; the real driver is wired by the application/test layer.

Case B follows that exact pattern but for PGMQ: add `Keiro.Inbox.Pgmq` and
`Keiro.Outbox.Pgmq` transport codecs/wiring that sit beside the Kafka ones, reusing the
PGMQ plumbing that `keiro-pgmq` already factored out. The key design rule — the reason this
plan stays cheap — is that case B builds on the **Runtime layer** of `keiro-pgmq`
(`Keiro.PGMQ.Runtime`: queue-name derivation, the `Pgmq : Tracing : Error : IOE` runner,
pool/tracer lifecycle) and **not** on the case-A `Job` layer. A `Job` is a background-work
abstraction; integration-event transport is a different concern that should not inherit the
Job/JobOutcome ergonomics.

What someone gains when this is eventually built: a keiro application can publish and
consume cross-context integration events over PGMQ (with topic fan-out for multiple
subscribers) instead of Kafka, configured under the same `Keiro.Inbox`/`Keiro.Outbox` seams
they already use — no Kafka broker required.


## Progress

- [ ] DEFERRED — not started. (When scheduled, replace this with real milestones.)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Record case B as a deferred plan rather than dropping it or folding it into the
  case-A package work.
  Rationale: The immediate need is case A; case B is a real future option for Kafka-averse
  teams and must not be lost. Capturing it now also lets us pin the integration constraint
  (build on `Keiro.PGMQ.Runtime`, not `Keiro.PGMQ.Job`) while that boundary is fresh.
  Date: 2026-06-07

- Decision: When built, case B lives as `Keiro.Inbox.Pgmq` / `Keiro.Outbox.Pgmq` transport
  codecs/wiring, siblings of the existing `Keiro.Inbox.Kafka` / `Keiro.Outbox.Kafka`.
  Rationale: Mirrors keiro's established "pure transport codecs, driver wired outside the
  framework" pattern, so PGMQ becomes one more transport rather than a new abstraction.
  Date: 2026-06-07


## Context and Orientation

This section records what a future implementer needs to know; it is not a call to act now.

Relevant existing seams in the keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro`:

- `keiro/src/Keiro/Inbox.hs` and `keiro/src/Keiro/Inbox/Kafka.hs` — the inbox: idempotent
  intake of inbound integration events, deduped by message/source identity. The `.Kafka`
  module is a pure codec (`integrationEventFromKafka` reconstructs an `IntegrationEvent`
  from Kafka headers + payload) with no `hw-kafka-client` dependency in the framework.
- `keiro/src/Keiro/Outbox.hs` and `keiro/src/Keiro/Outbox/Kafka.hs` — the outbox: durable
  handoff of outbound integration events with ordering policies. The `.Kafka` module is a
  pure codec (`outboxRowToKafkaRecord`).
- `keiro-core/src/Keiro/Integration/Event.hs` — the `IntegrationEvent` envelope contracts
  shared by inbox/outbox.

The `keiro-pgmq` package built by `docs/plans/55-...` provides, in its Runtime layer
(`Keiro.PGMQ.Runtime`): `QueueRef` (logical→physical+DLQ name derivation), `JobRuntime`,
`withJobRuntime`, and `runJobEff` (the `Pgmq : Tracing : Error PgmqRuntimeError : IOE`
runner). Case B reuses these. It must **not** import `Keiro.PGMQ.Job`.

PGMQ topic / fan-out facts (for the publish-to-many requirement): the PGMQ client exposes
topic operations (`bindTopic`, `sendTopic`, `listTopicBindings`) in pgmq ≥ 1.11, and
`shibuya-pgmq-adapter` already models a `TopicRoute`/`topicDeadLetter` target. A single
`sendTopic` publish can fan out to all queues bound to a routing key — this is the mechanism
that lets one outbound integration event reach multiple subscribing contexts. On-disk
source: `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs` and
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.


## Plan of Work

Deferred. A sketch of the eventual milestones, to be fleshed out when scheduled:

1. **Outbox over PGMQ** — `Keiro.Outbox.Pgmq`: a codec/wiring that turns an outbox row into
   a PGMQ topic publish (`sendTopic` with a routing key), reusing `Keiro.PGMQ.Runtime` for
   the connection/effect stack. Verify one publish fans out to multiple bound subscriber
   queues.
2. **Inbox over PGMQ** — `Keiro.Inbox.Pgmq`: consume from a subscriber queue (bound to the
   topic) and reconstruct an `IntegrationEvent` for the idempotent inbox, again on
   `Keiro.PGMQ.Runtime`.
3. **Topic/binding management** — idempotent setup of topics and per-subscriber bindings
   (the integration-event analogue of `ensureJobQueue`).
4. **A proving-ground migration** — point one cross-context link in `keiro-runtime-jitsurei`
   (which currently connects bounded contexts with Kafka + PGMQ work queues) at the PGMQ
   integration-event transport, demonstrating Kafka-free cross-context delivery.

Each milestone, when written, must conform to the ExecPlan specification (self-contained,
observable acceptance) just like the other plans in this initiative.


## Validation and Acceptance

Deferred. When scheduled, acceptance is: a domain integration event published from one
bounded context over PGMQ is received by two or more subscribing contexts (proving fan-out),
configured under `Keiro.Outbox`/`Keiro.Inbox`, with no Kafka broker in the loop — verified
by an end-to-end scenario in a proving-ground app.


## Idempotence and Recovery

Deferred. The relevant constraints when built: topic/binding setup must be idempotent (like
`ensureJobQueue`); inbox intake must remain idempotent by integration-event identity (the
existing inbox dedup contract).


## Interfaces and Dependencies

The single hard design constraint recorded now (also captured as Integration Point 2 in the
MasterPlan `docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md`): case B builds on
`Keiro.PGMQ.Runtime` (the transport-agnostic layer) and must **not** depend on
`Keiro.PGMQ.Job` (the case-A background-work layer). `docs/plans/55-...` is responsible for
keeping those two layers cleanly separable precisely so this plan stays cheap. If, when this
plan is scheduled, the Runtime layer has accreted Job-specific concerns, the first task is to
re-separate them before adding the Inbox/Outbox transports.
</content>
