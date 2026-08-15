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
| [Typed event streams, codecs, and schema evolution](typed-event-model.md) | CAP-1 | 0.1.0.0 | Typed stream names, codec-wide versions, event-type validation, upcasters |
| [Replay-safety validation boundary](replay-safety-validation.md) | CAP-2 | 0.1.0.0 | Rejecting un-replayable transducers before they run commands |
| [The transactional command cycle](transactional-command-cycle.md) | CAP-3 | 0.1.0.0 | load → replay → decide → optimistic append, with a transactional step |
| [Advisory aggregate and process-manager snapshots](advisory-snapshots.md) | CAP-4 | 0.1.0.0 | Hydration acceleration that never becomes load-bearing |
| [Registered read models and fenced projections](read-models-and-projections.md) | CAP-5 | 0.1.0.0 | Inline/async projections, strong reads, atomically fenced rebuilds |
| [Typed projection catalogs and coordinated rebuilds](typed-projection-catalogs.md) | CAP-6 | 0.12.0.0 | Typed inventory, resumable group rebuilds, online revision cutover, targeted repair |
| [Process managers, routers, and durable timers](process-managers-routers-timers.md) | CAP-7 | 0.1.0.0 | Event-sourced reaction: source events → target commands, with timers |
| [Durable execution (the Workflow effect)](durable-execution.md) | CAP-8 | 0.1.0.0 | Named-step resume, suspensions, version patches, and generation rotation |
| [Transactional outbox with Kafka adapter](transactional-outbox.md) | CAP-9 | 0.1.0.0 | Transactional production plus an ordered, retrying transport drain |
| [Idempotent inbox with Kafka adapter](idempotent-inbox.md) | CAP-10 | 0.1.0.0 | At-most-once database effects per retained deduplication identity |
| [Dead-letter records and controlled replay](dead-letter-tooling.md) | CAP-11 | 0.1.0.0 | Durable rejected-dispatch records and classified handler-driven replay |
| [PostgreSQL work queues (keiro-pgmq)](postgres-work-queues.md) | CAP-12 | 0.1.0.0 | Typed background jobs on a Postgres-native queue, no broker |
| [Native database migrations and keiro-migrate](database-migrations.md) | CAP-13 | 0.1.0.0 | Dependency-ordered schema install/upgrade and a CLI |
| [Typed-spec (.keiro) toolchain](typed-spec-toolchain.md) | CAP-14 | 0.1.0.0 | Author, check, scaffold, and evolution-gate services from a spec |
| [OpenTelemetry instrumentation](opentelemetry-instrumentation.md) | CAP-15 | 0.1.0.0 | Spans and metrics across framework delivery and handler paths |
| [Schema-aware operational console](operational-console.md) | CAP-16 | 0.12.0.0 | Standalone/embedded inspection and preview-before-force repair workflows |
| [Guarded external read-model contracts](guarded-external-read-models.md) | CAP-17 | 0.12.0.0 | Versioned execute-only SQL contracts safe across projection cutovers |
| [Typed domain command outcomes](typed-domain-command-outcomes.md) | CAP-18 | 0.12.0.0 | Accepted event batches plus typed business rejection and no-op decisions |
| [Canonical integration-event envelope](canonical-integration-events.md) | CAP-19 | 0.1.0.0 | Transport-neutral public event identity, metadata, payload, and trace contract |

## Published-package coverage

The 0.12.0.0 release publishes six packages. Every one maps to at least one
record, while internal-only support packages are called out below:

| Published package | Capability records |
|---|---|
| `keiro-core` | CAP-1, CAP-2, CAP-4, CAP-19 |
| `keiro` | CAP-2 through CAP-11, CAP-15, CAP-17, CAP-18 |
| `keiro-pgmq` | CAP-12, CAP-15 |
| `keiro-migrations` | CAP-13, CAP-17 |
| `keiro-dsl` | CAP-6, CAP-14, CAP-17, CAP-18 |
| `keiro-ops` | CAP-16 |

The `interface` field names the principal public adoption entry points, not
every exposed implementation facet. Public `*.Schema`, `*.Types`, rendering,
parser, compatibility, and generated-toolchain analysis modules remain part of
the capability record that owns their behavior unless they form a separately
adopted and evidenced contract.

## Deliberately excluded

These surfaces exist in the repository but are **not** capability records, with
the reason under the three rules (evidence; provision-not-composition; one
independently-adopted-and-verified thing):

- **Sharded subscription workers** (`Keiro.Subscription.Shard*`) — public,
  tested, documented, and operable through CAP-16, but a consumer does not adopt
  sharding independently of the subscription workers that carry projections and
  process managers. It remains an advanced runtime knob of CAP-5 / CAP-7 rather
  than a top-level capability.
- **`keiro-test-support`** (`Keiro.Test.Postgres`) — shared ephemeral-Postgres
  test fixtures. It is development tooling a consumer uses to *test* a
  keiro-based service, not a runtime capability the service provides to its own
  consumers. Excluded as infrastructure.
- **`jitsurei`** — runnable, database-backed examples and conformance evidence
  for the capabilities above. It is not a published runtime package or a surface
  a service adopts in production.
- **Supporting module granularity** — umbrella re-exports, schema constants and
  row types, typed identity helpers, and the many parser/checker/scaffolder
  analysis modules are public building blocks of the records above. Module count
  alone does not turn each building block into a separately adopted capability.
- **Composition claims** — anything true only when keiro cooperates with
  [Kiroku](mori://shinzui/kiroku), [Keiki](mori://shinzui/keiki), or
  [Shibuya](mori://shinzui/shibuya) as separate repositories belongs to the
  consuming repository as a use-case feature, not to keiro's capability catalog
  (rule 2).

## Evidence discipline

`evidence[].resource` paths are repository-wide and are not checked by `okf`;
every path in this bundle was confirmed to exist at authoring time. Broad
runtime behavior is proven by `keiro/test/Main.hs`; specialized read-side
behavior has focused catalog, versioned-rebuild, and external-read suites;
CAP-16 has a package-level PostgreSQL integration suite; and the `.keiro`
toolchain (CAP-14) is additionally proven by conformance packages that compile
and pin generated output.
