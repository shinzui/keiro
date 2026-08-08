---
okf_version: "0.2"
---

# keiro capabilities

What the **keiro** framework provides to a consumer today: what a project can
depend on, adopt, and verify against evidence it can open. Each record is one
capability — one thing a consumer adopts *and* verifies independently — backed by
at least one artifact (a test, a conformance suite, a worked example, a guide, or
a module) that a reader can open. There is no roadmap here: a capability that
does not yet exist is an improvement request, not a record.

keiro is a Haskell event-sourcing and workflow framework over a single Postgres
event log. It is pre-1.0 and under active development: every capability below is
**shipped** but **experimental** in its compatibility promise — that uniformity
reflects the project's single, uniform stability policy, not a missing
distinction.

## What keiro provides

| Capability | Handle | Since | Provides |
|---|---|---|---|
| [Typed event streams, codecs, and schema evolution](typed-event-model.md) | CAP-1 | 0.1.0.0 | Typed stream names, versioned codecs, event-type validation, upcasters |
| [Replay-safety validation boundary](replay-safety-validation.md) | CAP-2 | 0.1.0.0 | Rejecting un-replayable transducers before they run commands |
| [The transactional command cycle](transactional-command-cycle.md) | CAP-3 | 0.1.0.0 | load → replay → decide → optimistic append, with a transactional step |
| [Advisory aggregate snapshots](advisory-snapshots.md) | CAP-4 | 0.1.0.0 | Hydration acceleration that never becomes load-bearing |
| [Registered read models and fenced projections](read-models-and-projections.md) | CAP-5 | 0.1.0.0 | Inline/async projections, strong reads, atomically fenced rebuilds |
| [Typed projection catalogs and coordinated rebuilds](typed-projection-catalogs.md) | CAP-6 | unreleased | A typed inventory and group-atomic multi-target rebuilds |
| [Process managers, routers, and durable timers](process-managers-routers-timers.md) | CAP-7 | 0.1.0.0 | Event-sourced reaction: source events → target commands, with timers |
| [Durable execution (the Workflow effect)](durable-execution.md) | CAP-8 | 0.1.0.0 | Named-step journaling, crash-safe resume, sleep/awakeable/child |
| [Transactional outbox with Kafka adapter](transactional-outbox.md) | CAP-9 | 0.1.0.0 | Outbound messages committed with the events that produced them |
| [Idempotent inbox with Kafka adapter](idempotent-inbox.md) | CAP-10 | 0.1.0.0 | Exactly-once-by-effect consumption of redelivered messages |
| [Dead-letter records and idempotent replay](dead-letter-tooling.md) | CAP-11 | 0.1.0.0 | Durable rejected-dispatch records and safe DLQ replay |
| [PostgreSQL work queues (keiro-pgmq)](postgres-work-queues.md) | CAP-12 | 0.1.0.0 | Typed background jobs on a Postgres-native queue, no broker |
| [Native database migrations and keiro-migrate](database-migrations.md) | CAP-13 | 0.1.0.0 | Dependency-ordered schema install/upgrade and a CLI |
| [Typed-spec (.keiro) toolchain](typed-spec-toolchain.md) | CAP-14 | 0.1.0.0 | Author, check, scaffold, and evolution-gate services from a spec |
| [OpenTelemetry instrumentation](opentelemetry-instrumentation.md) | CAP-15 | 0.1.0.0 | Spans and metrics across every delivery and handler |

## Deliberately excluded

These surfaces exist in the repository but are **not** capability records, with
the reason under the three rules (evidence; provision-not-composition; one
independently-adopted-and-verified thing):

- **Sharded subscription workers** (`Keiro.Subscription.Shard*`) — public and
  well-tested (`keiro/test/Main.hs` "Shard lease" / "Sharded subscription …"
  blocks) and named in `docs/user/api-reference.md`, but there is no conceptual
  adoption guide, and a consumer does not adopt sharding *independently* of the
  subscription workers that carry projections and process managers. Treated as an
  advanced runtime knob of CAP-5 / CAP-7, not a top-level capability. This is a
  documentation gap the run surfaced (see `log.md`).
- **`keiro-test-support`** (`Keiro.Test.Postgres`) — shared ephemeral-Postgres
  test fixtures. It is development tooling a consumer uses to *test* a
  keiro-based service, not a runtime capability the service provides to its own
  consumers. Excluded as infrastructure.
- **Composition claims** — anything true only when keiro cooperates with kiroku,
  keiki, or shibuya as separate repositories belongs to the consuming repository
  as a use-case feature, not to keiro's capability catalog (rule 2).

## Evidence discipline

`evidence[].resource` paths are repository-wide and are not checked by `okf`;
every path in this bundle was confirmed to exist at authoring time. The strongest
evidence is the test surface: the runtime capabilities are proven by the
monolithic `keiro/test/Main.hs` suite, and the `.keiro` toolchain (CAP-14) is
additionally proven by a family of conformance suites that pin generated output.
Where a capability's evidence is weaker than the rest — CAP-6 is unreleased and
guide-less — the record says so.
