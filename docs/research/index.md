# Subdirectories

- [notes/](notes/index.md)

# Research Document

- [Research Overview — 経路 (keiro)](00-overview.md) - Synthesize the Keiro research corpus and index its supporting surveys and designs.
- [Kiroku Event Store — Current State Survey](01-kiroku-read-side.md) - Survey Kiroku's read-side, append, subscription, snapshot, and transaction capabilities relevant to Keiro.
- [Keiki Functional Core — Current State Survey](02-keiki-decide-loop.md) - Survey Keiki's symbolic transducer, decide, evolve, composition, codec, and testing surfaces.
- [Shibuya Subscription Engine — Current State Survey](03-shibuya-subscriptions.md) - Survey Shibuya's adapters, checkpointing, concurrency, failure, lifecycle, and observability behavior.
- [Kiroku × Keiki Integration — Current State of the Command Cycle](04-kiroku-keiki-integration.md) - Evaluate how Kiroku and Keiki compose into Keiro's command cycle and identify the remaining integration gaps.
- [Workflow & Durable-Execution Prior Art — Survey for keiro](05-workflow-prior-art.md) - Compare workflow and durable-execution systems to identify capabilities Keiro should adopt or avoid.
- [Command Cycle Design — keiro](06-command-cycle-design.md) - Derive Keiro's command-cycle contract, API, transaction behavior, retries, idempotency, and telemetry.
- [Codec and Event Schema Strategy — keiro](07-codec-strategy.md) - Define Keiro's event codec, type-tag, schema-version, upcaster, unknown-event, and testing strategy.
- [Subscriptions, Projections, and Process Managers — keiro](08-subscription-and-process-manager-design.md) - Design Keiro's projection, process-manager, inbox, outbox, concurrency, failure, and observability surfaces.
- [keiro snapshot strategy and hydration acceleration](09-snapshot-strategy.md) - Design advisory snapshots, compatibility checks, policies, read/write paths, retention, and operations.
- [Workflow Engine and Durable Execution Roadmap — keiro](10-workflow-roadmap.md) - Define Keiro's v1 workflow scope and the path to named-step durable execution in v2.
- [Upstream Roadmap for Kiroku and Keiki — keiro](11-upstream-roadmap.md) - Track upstream Kiroku and Keiki capabilities required or desired by Keiro and their delivery status.
- [Read Model Query API and Lifecycle Design](12-read-model-query-api-and-lifecycle.md) - Design typed read-model queries, consistency modes, lifecycle operations, and their substrate contracts.
- [Case study — wiring the AgentQualification decomposition onto keiro](13-agent-qualification-runtime-wiring.md) - Map the AgentQualification decomposition onto Keiro streams, routing, process managers, read models, and integration edges.
- [Structural Consumer Types: What Keiro Gives Up and How to Recover It Safely](14-structural-consumer-type-tradeoffs.md) - Evaluate the costs of structural and opaque consumer-owned types and identify safe ergonomic improvements.
- [OpenTelemetry semantic-conventions audit](opentelemetry-semconv-audit.md) - Audit Keiro instrumentation sites against the OpenTelemetry semantic conventions and record gaps and actions.
