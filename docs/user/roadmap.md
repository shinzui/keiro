---
type: Reference
title: Keiro Roadmap
description: Track the 0.22 capability baseline, remaining runtime work, adoption boundaries, and pre-1.0 language stability.
docId: DOC-21
tags: [keiro, roadmap, planning, reference]
generated:
  by: human:nadeem
  at: 2026-09-18T04:06:27Z
timestamp: 2026-10-27T21:15:00Z
---

# Keiro Roadmap

This page separates the shipped **0.22.0.0** baseline from remaining work.
It describes adoption constraints, not delivery dates. The
[root changelog](../../CHANGELOG.md) records release changes;
[Production Status](production-status.md) describes the current adoption posture.

## Current Baseline

Eight published packages share the Keiro version: `keiro-core`, `keiro`,
`keiro-pgmq`, `keiro-dsl`, `keiro-migrations`, `keiro-ops`, `keiro-ops-http`,
and `keiro-test-support`. `jitsurei` is the repository's runnable example.
The workspace uses GHC 9.12.4 and PostgreSQL 18 through `nix develop`.

| Capability | Shipped behavior | Adoption boundary |
|---|---|---|
| Typed streams and codecs | Category-safe stream construction, event-type validation, schema versions, upcasters, structural/nominal/refined mappings | Applications own retained-history compatibility. |
| Command execution | `ValidatedEventStream`, streaming replay, optimistic retries, multi-event appends, typed rejection/no-op outcomes, transactional SQL continuations | External retries need stable event IDs; network effects need durable handoff. |
| Snapshots and replay audit | Advisory snapshots, fold fingerprints, sampled seed verification, real-log candidate-code audit | A sampled runtime witness does not replace a pre-deploy replay gate. |
| Projection catalogs | Validated ownership, inline/async delivery, query-supplier resolution, freshness choices, group fencing | Applications own DDL, SQL, reset truthfulness, and replay adapters. |
| Rebuilds and repair | Fixed-head coordinated offline rebuilds, schema-versioned online catch-up/cutover, resume, and stream-scoped repair | Clear/preserve policy and verification remain explicit application choices. |
| Guarded catalog commands | Transaction-local relational preconditions with typed refusal and rollback | Keep invariant state small; inline SQL extends the global append-lock interval. |
| Coordination | Legacy process managers, typed reactions, routers, durable timers, rejected-dispatch records | Reaction identity differs from positional dispatch; switching requires a drained cutover. |
| Durable workflows | Named steps, durable sleep, awakeables, children, resume, snapshots, `patch`, and `continueAsNew` | Keep replayed step names/result codecs compatible and external effects idempotent. |
| Messaging | Transactional outbox, deterministic producer identities, inbox deduplication, delegated intake, Kafka adapters | Delivery remains at-least-once; identity and retention policies are part of the contract. |
| Work queues | Typed PGMQ jobs, versioned payloads, retries, DLQ operations, `FifoHeads`, partitioned provisioning | PGMQ migration 0007 precedes traffic; partitioned queues retain polling. |
| Delivery and scale-out | Push wakeups with poll fallback and leased category-subscription sharding | Size concurrency against database capacity; notifications are hints. |
| Migrations | Dependency-ordered native plan, ledger verification, live schema checks, legacy history import | Upgrade ordering can require stopped workers or writers. |
| Operations | Schema-checked CLI, mounted aggregate/manager discovery and state, bounded workflow/timer/projection pages, shard observations | Application-specific capabilities are mounted through `emptyAppHooks` updates. |
| HTTP and feeds | Optional HTTP operations, shared first-page WebSocket feeds, stable-prefix application composition | Use a dedicated inspection store, explicit budgets, and paired poll recovery. |
| Typed specifications | Stable Language 5 and candidate Language 6 in the released `keiro-dsl` toolchain | Package publication does not stabilize the candidate language. |

## Read-side And Subscription Maturity

### Async delivery and deduplication

Async subscription delivery is at-least-once. Keiro's async apply transaction
commits the dedup receipt and handler SQL together, so retained receipts suppress
reapplication of the same projection/event identity. Subscription checkpoint
advancement remains a separate boundary: delivery can repeat after a crash.
Pruning dedup receipts beyond the replay window removes that protection for the
pruned events. Keep handler SQL idempotent where practical.

Combining application writes with subscription checkpoint advancement remains
upstream-dependent. Do not assume the current API provides that transaction.
See [Asynchronous Projections](../guides/asynchronous-projections.md).

### Category and namespace subscriptions

The [Kiroku Store](mori://shinzui/kiroku/packages/kiroku-store) 0.12 cohort
ships `CategoryNamespace`, alongside `AllStreams` and exact `Category` targets.
For example, namespace `pm` includes category `pm` and colon-separated
descendants such as `pm:billing`; it is not an arbitrary stream-name prefix or
wildcard. Namespace catch-up scans global windows, so sparse matches still incur
scan work and each consumer-group member performs its own scan.

Stop affected subscription workers before applying Kiroku migration 0016, then
restart new binaries before creating namespace bindings. Older binaries must
not manage those bindings. See [Deploy Ordering](deploy-ordering.md).

Keiro's projection catalog, DSL source declarations, and category sharding
helpers retain their declared all-stream/exact-category contracts. An upstream
namespace target does not automatically extend these surfaces. Workflow resume
uses its own exact runnable-instance discovery and does not require a namespace
subscription.

### Position waits and push delivery

`Keiro.Wake` and push-aware workers already use Kiroku's existing notifier with
a durable poll fallback. `Keiro.ReadModel` position waits still poll; wiring wake
hints into that path remains separate work. Notifications can reduce latency,
but durable checkpoints remain the correctness authority.

For new query models, default to async delivery and `Immediate` freshness.
When a response needs a projected view, wait for the command's committed
position after the append returns. Reserve inline work for a stated atomic
invariant. See [Choosing A Projection](../guides/choosing-a-projection.md).

## Language And API Stability

Language 5 remains the published stable contract and is what `keiro-dsl new`
selects. Language 6 ships as a candidate, including process reactions, delegated
intake, `fifo-heads`, nominal structural leaves, checked value mappings, contract
lists, mapped-register construction, and exact structural enum equality.
The [DSL reference](keiro-dsl-reference.md) lists the gates and topic references.

The pre-1.0 policy in
[ADR 49](../adr/0049-language-6-is-the-sole-pre-1-0-coverage-and-data-support-baseline.md)
selects Language 6 as the eventual sole coverage/data-support baseline.
Languages 1–4 are deprecated today; Languages 1–5 and legacy positional managers
are scheduled to retire before 1.0. That future retirement does not make the
candidate stable today or make an existing service's data migration automatic.

The Haskell API is still pre-1.0 and can break between coordinated releases.
Regenerate machine-owned output, preserve create-once application modules, and
compile consumers against one package cohort. Source API migrations belong in
release notes and the [upgrade blueprint](../../blueprints/keiro-upgrade/README.md).

## Adoption And API Ergonomics

The worked application, guide-backed tests, generated conformance harnesses,
replay evidence gates, CLI, HTTP transport, and feeds are available. Remaining
adoption work includes broader Haddock coverage, a stronger public stability
policy, and consumer-specific production qualification.

Application responsibilities remain explicit:

- own read-model migrations, SQL, codecs, and historical-corpus selection;
- rehearse database upgrades, restores, rebuilds, and operator repair;
- test replay and idempotency against retained production-shaped history;
- measure the actual writer, projection, inspection, and worker workload.

No calibrated throughput or latency promise follows from the presence of a
benchmark or a bounded API. In particular, guarded commands and inline handlers
extend the shared append transaction.

## Durable Execution Boundaries

The named-step durable runtime is implemented, including journal rotation,
patches, child completion/cancellation, push-aware resume, and journal snapshots.
These features are available in the current package set.

A parked workflow is excluded from runnable discovery until its wake condition
changes. Due sleep timers, crash retries, and replay still cost work. Set an
appropriate snapshot policy for long journals and size resume concurrency
against the store pool. See
[What suspension costs](durable-workflows.md#what-suspension-costs).

A step's external action and its result journal are separate commits. A crash
between them can repeat the action. Renaming a step creates a new durable action;
it is not a compatibility-preserving edit for retained runs. `continueAsNew`
starts a new generation and requires re-notifying holders of newly allocated
awakeable IDs. See [Deploy Ordering](deploy-ordering.md) and
[Durable Workflows](durable-workflows.md).

## Longer-term Possibilities

Schema-registry integration, field-level encryption, alternative snapshot
encodings, and multi-region operation remain demand-driven design work.
The current runtime assumes one PostgreSQL ordering authority. Server-side
scripted projections were declined; a Decider-style facade was also declined
in favor of the validated transducer and generated authoring surface.
