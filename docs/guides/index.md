---
okf_version: "0.2"
---

# Explanation

- [The Guarantee Ledger: DSL and Hand-Written Services](dsl-guarantees-and-hand-written-services.md) - Compare the guarantees supplied by generated and hand-written Keiro service layers.

# Guide

- [Adopting keiro-dsl generated Haskell idiomatic-v2](adopting-keiro-dsl-idiomatic-v2.md) - Adopt the idiomatic-v2 generated Haskell surface and its compatibility gates.
- [Adopting Keiro From tan-event-source](adopting-keiro-from-tan-event-source.md) - Migrate a service from tan-event-source to Keiro in controlled compatibility stages.
- [Asynchronous Projections](asynchronous-projections.md) - Build eventually consistent read models with durable asynchronous delivery.
- [Brownfield Migration And Transducer Modeling](brownfield-migration-and-transducer-modeling.md) - Introduce Keiro incrementally while modeling state transitions as explicit transducers.
- [Choosing A Primitive](choosing-a-primitive.md) - Choose among Keiro primitives by durability, ordering, latency, and operational needs.
- [Choosing A Projection](choosing-a-projection.md) - Choose inline, asynchronous, or rebuilt projections for a read-model workload.
- [Choosing `keiro-dsl`: Benefits, Costs, and Fit](choosing-keiro-dsl.md) - Decide whether generated services fit a context's guarantees, workflow, and maintenance needs.
- [Evolution And Replayability](evolution-and-replayability.md) - Preserve replayability while evolving events, folds, snapshots, and projections.
- [Evolve Events Safely](evolve-events-safely.md) - Evolve stored event schemas with versioned codecs, upcasters, and replay verification.
- [Inline Projections](inline-projections.md) - Build transactionally consistent read models inside the command transaction.
- [Integration Events With Kafka](integration-events-with-kafka.md) - Publish and consume Keiro integration events through Kafka with stable envelopes.
- [Migrating to the keiro-dsl 0.15 record API](migrating-keiro-dsl-record-api-0.15.md) - Update generated consumers and services for the keiro-dsl 0.15 record API.
- [Migrating to `ValidatedEventStream`](migrating-to-validated-event-stream.md) - Move aggregate hydration and folds onto Keiro's replay-safe validated stream boundary.
- [Process Managers And Timers](process-managers-and-timers.md) - Coordinate multi-step processes with persisted manager state and durable timers.
- [Project Read Models](project-read-models.md) - Implement query-oriented read models from event streams with explicit delivery semantics.

# Navigation

- [Keiro Guides](README.md) - Route readers through Keiro tutorials, adoption guides, design explanations, and operational runbooks.

# Runbook

- [Offline Projection Rebuilds](offline-projection-rebuilds.md) - Rebuild a projection while reads are stopped or safely routed away.
- [Online Schema-Versioned Projection Rebuilds](online-projection-rebuilds.md) - Rebuild and cut over schema-versioned projections without stopping reads.
- [Run And Operate Jitsurei](run-and-operate-jitsurei.md) - Run, inspect, recover, and verify the Jitsurei reference application.

# Tutorial

- [Build The Command Side](build-the-command-side.md) - Build an aggregate command path with decisions, persistence, and optimistic concurrency.
- [Coordinating Incident Response: Routers And Process Managers Together](coordinating-incident-response-with-routers-and-process-managers.md) - Combine routing and persisted coordination in an end-to-end incident response workflow.
- [Durable Workflows](durable-workflows.md) - Build a durable workflow with persisted progress, retryable effects, and resumable execution.
- [Order Fulfillment Overview](order-fulfillment-overview.md) - Follow the Jitsurei order-fulfillment system from commands through projections and background work.
- [Routers And Effectful Fan-Out](routers-and-effectful-fan-out.md) - Route one event to multiple effectful consumers with explicit failure behavior.
- [Snapshots And Hydration](snapshots-and-hydration.md) - Add advisory snapshots to aggregate hydration while preserving event-log authority.
- [Work Queues](work-queues.md) - Build and operate a typed PGMQ worker with retries, FIFO groups, and dead letters.

