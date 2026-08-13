---
type: Architecture Decision Record
title: Operator commands wrap supported library APIs and respect schema ownership
description: Keiro operator commands preserve library invariants, schema ownership, destructive previews, and the standalone-versus-embedded capability boundary.
timestamp: 2026-08-13T17:46:56Z
docId: ADR-28
status: Accepted
date: 2026-08-08
---

# 28. Operator commands wrap supported library APIs and respect schema ownership

Date: 2026-08-08

Status: Accepted


## Context

Keiro exposes supported library operations for workflow lifecycle changes, timer
triage, messaging recovery, projections, snapshots, and event-store lifecycle
management. An operational console is valuable only if it preserves the same
transactional and idempotence guarantees as application code. Direct console SQL
would create a second behavioral implementation of those guarantees and could let
an operator produce state that the runtime cannot replay or reconcile.

The operational surface spans schemas owned by different libraries. Keiro owns its
workflow and runtime tables, `mori://shinzui/kiroku/packages/kiroku-store` owns the
event-store schema, and the PGMQ libraries own queue state. A convenient shared
database connection does not transfer ownership of one library's schema to another.

Some operations require only a database connection, while others require the
application's compiled workflow registry, codecs, handlers, or replay-audit targets.
A standalone executable cannot discover those application values from the database.
Timer draining is one such operation because the worker delegates dispatch and the
fired event id to an application-supplied callback.

Catalog adoption is another compiled-code operation. The database can expose a
stored group slice but cannot reconstruct the application's current validated
catalog or decide whether a changed slice is safe for application-owned rows.

Kiroku 0.4.0.0 now exports `subscriptionCheckpointInventory`, a one-statement
snapshot of the global store cursor and every durable, member-aware subscription
checkpoint. Before that API existed, neither Kiroku's process-local live worker
registry nor Keiro's private `subscriptions`-table query was a valid basis for an
operator command. The public inventory makes durable reporting possible without
transferring schema ownership to Keiro.


## Decision

Every operator command is a thin adapter over an exported operation from the library
that owns the affected state. A command must not reproduce a supported mutation with
ad hoc SQL, and it must not query or mutate another library's private tables. When an
operator primitive is missing, it is added and tested in the owning library before a
command exposes it.

Durable Kiroku checkpoint commands call
`Kiroku.Store.Subscription.subscriptionCheckpointInventory` and preserve every
member row. A subscription-wide checkpoint is the minimum across matching members;
member zero does not identify whether the subscription is grouped. The commands also
call `Keiro.ReadModel.storeHeadPosition` for the newest visible event. They report the
inventory's authoritative append counter as `store_position`, report the reachable
event boundary as `visible_store_head`, and subtract each checkpoint from the visible
head for **global position distance**. That subtraction is never called event lag,
backlog, or events behind. A global cursor may be sparse for a filtered, category,
hard-deleted, or sharded history, so a true relevant-event lag requires a compatible
frontier and definition exported by the owning library. [ADR 0033](0033-consistency-waits-target-reachable-visible-heads.md)
defines why the authoritative counter is not a consistency-wait or distance target.

Every destructive command has two phases. Without `--force`, it performs only the
supported read or preview path, renders the rows or objects that would be affected,
prints the exact force-enabled re-invocation, and exits unsuccessfully without a
mutation. With `--force`, it calls the supported mutation and reports the actual
outcome, including idempotent no-ops and already-terminal states.

The executable verifies the live Keiro schema with
`Keiro.Migrations.SchemaCheck.verifyExpectedSchema` before opening the operational
environment. Read-only commands may continue after rendering drift warnings.
Mutating commands refuse drift by default and require the explicit
`--allow-schema-drift` override in addition to `--force`. Schema verification remains
owned by the mechanism established in
[ADR 9](0009-keiro-owns-live-schema-verification-under-pg-migrate.md).

The `keiro-ops` package provides an embeddable command library and a thin standalone
binary. The standalone binary exposes only database-only commands. Commands that
need application code are mounted through explicit application-supplied hooks in an
embedding binary; the CLI never invents a database representation of those values.
`rebuild adopt` is consequently mounted only with a validated catalog hook. Its
preview and mutation call the supported slice-adoption operations from
[ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md).

Schema-versioned rebuild commands follow the same boundary. An application-owned
provisioner and validator define the desired target schema; the supported Keiro library
operation supplies allocated physical names and owns the transaction, replay, cutover,
and retirement protocol. Commands that start, resume, promote, or abandon such a run
are embedded-only because they require the compiled catalog revisions. Database-only
inspection and dependency-aware retired-generation drop may remain standalone. A
command never substitutes inferred DDL or private Kiroku SQL for a missing owner API.


## Consequences

- Workflow cancellation, failure resurrection, awakeable settlement, and timer
  recovery inherit the runtime's existing race and append-only behavior from
  [ADR 6](0006-workflow-wake-source-rows-govern-exposure-and-terminal-races.md),
  [ADR 7](0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md),
  [ADR 8](0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md),
  and
  [ADR 27](0027-workflow-lifecycle-markers-are-append-only-and-first-writer-wins.md).
- A command may need an upstream library change before it can ship. That dependency
  is deliberate evidence that the invariant has one owner.
- JSON and human table output are alternative renderings of the same structured
  handler result, so scripts do not depend on terminal formatting.
- Destructive numeric parameters are validated before database access. A preview
  computed from an unrepresentable cutoff is a lie, so non-finite, negative, and
  PostgreSQL `timestamptz`-unrepresentable durations never reach either the preview
  or mutation phase.
- `stream subscriptions` and `projection position` remain database-only and
  read-only. They expose stopped-worker checkpoint rows and both store heads
  without consulting the process-local subscription registry, scanning category
  history, or adding an application hook.
- Dashboards migrate from `keiro.projection.lag` to
  `keiro.projection.global_position_distance`; the old gauge is a one-series
  compatibility alias with the same position-unit value, not permission to retain
  the event-count interpretation.
- A future TUI or web console can reuse the command handlers and application hooks;
  it does not receive permission to bypass the library boundary.
- Application-provisioned schema generations do not transfer schema authorship to
  Keiro. Keiro owns orchestration evidence and safe destructive previews; the
  application remains responsible for DDL meaning and compatibility validation.


## References

- [MasterPlan 31](../masterplans/31-build-the-keiro-ops-operational-cli.md)
  coordinates the operational CLI initiative.
- [ExecPlan 206](../plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md)
  establishes the package, safety rails, and first command domains.
- [ExecPlan 214](../plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory.md)
  adopts Kiroku's released durable inventory and defines the position-distance
  operator and telemetry surfaces.
- [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  defines the catalog adoption preview, transaction, and compiled-catalog
  capability boundary.
- [ADR 0033](0033-consistency-waits-target-reachable-visible-heads.md) separates
  the authoritative append counter from reachable wait and distance targets.
- [ADR 0034](0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
  defines the application-provisioner and Keiro-orchestration boundary for online
  schema-changing projection rebuilds.
