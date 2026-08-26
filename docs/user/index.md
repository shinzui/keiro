---
okf_version: "0.2"
---

# Explanation

- [Codecs And Event Evolution](codecs-and-event-evolution.md) - Explain event tags, schema versions, upcasters, codec authority, and decode failures.
- [Command Cycle](command-cycle.md) - Explain command hydration, decisions, optimistic concurrency, retries, idempotency, and inline SQL.
- [Core Concepts](core-concepts.md) - Introduce streams, codecs, commands, projections, process managers, and timers.
- [Integration Events](integration-events.md) - Explain domain and integration events and the public cross-context envelope.
- [Migration Ownership](migration-ownership.md) - Explain framework and application migration ownership, ledgers, roles, and operator checks.
- [Process Managers And Timers](process-managers-and-timers.md) - Explain event-sourced coordination, deterministic command IDs, and durable timer workers.
- [Replayability Safety](replay-safety.md) - Explain the replay-safety guarantee, its limits, and the ValidatedEventStream boundary.

# Guide

- [Adopting Mapped Consumer Surfaces](mapped-consumer-adoption.md) - Adopt Language 5 mapped declaration surfaces through the stable rollout gate.

# Navigation

- [Keiro User Guide](README.md) - Route readers through Keiro concepts, adoption guidance, operational documentation, and API reference.

# Reference

- [API Reference](api-reference.md) - Map Keiro's public modules and their user-facing interfaces.
- [Durable Workflows](durable-workflows.md) - Reference named steps, durable waits, awakeables, child workflows, resume workers, and journal snapshots.
- [Idempotent Inbox](inbox.md) - Reference inbox deduplication policies and transactional handler semantics.
- [Durable Outbox](outbox.md) - Reference durable outgoing integration handoff, ordering, dead letters, and publishing.
- [Production Status](production-status.md) - State Keiro's production maturity, supported adoption posture, and intentionally deferred work.
- [Read Models And Projections](read-models-and-projections.md) - Reference projection catalogs, delivery modes, query freshness, and rebuild lifecycles.
- [Keiro Roadmap](roadmap.md) - Track capability maturity, adoption milestones, and future durable-execution direction.
- [Snapshots](snapshots.md) - Reference advisory snapshots, fold versions, hydration behavior, and operations.
- [Keiro DSL Language 5 Reference](typed-spec-toolchain.md) - Define the stable Language 5 grammar, toolchain, ownership, validation, and evolution workflow.
- [Work Queues](work-queues.md) - Reference typed PGMQ jobs, workers, retries, FIFO groups, and dead-letter operations.

# Runbook

- [Dead Letters And Replay](dead-letters.md) - Inspect and replay dispatch and subscription dead letters safely and idempotently.
- [Deploy Ordering](deploy-ordering.md) - Choose safe rollout order for codecs, jobs, timers, integration messages, and workflows.
- [Database Migrations](migrations.md) - Install, upgrade, and verify Keiro framework database migrations.
- [Operations](operations.md) - Deploy and operate Keiro applications, workers, rebuilds, retries, and production checks.
- [Upgrading To The Keiro Schema](upgrading-to-the-keiro-schema.md) - Upgrade an existing database to the Keiro schema while preserving migration history.

# Tutorial

- [Getting Started](getting-started.md) - Build a first Keiro integration from database setup through a command path.

