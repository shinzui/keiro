---
type: Architecture Decision Record
title: Operator commands wrap supported library APIs and respect schema ownership
description: Keiro operator commands preserve library invariants, schema ownership, destructive previews, and the standalone-versus-embedded capability boundary.
timestamp: 2026-10-21T01:53:43Z
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

Authorization to execute does not override a supported library safety refusal. In
particular, forced PGMQ DLQ purge calls `Keiro.PGMQ.Dlq.purgeDlq` and reports either
its deleted count or its typed hidden-row refusal. The command does not call the
unconditional `purgeDlqForce` escape hatch. The library guard is a metrics snapshot
followed by deletion, not a lock; an audit-safe full-queue procedure must quiesce
concurrent readers and writers, archive every inspected id, and account for the
remaining active depth before purge.

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
listing of retired generations needs no compiled code. Versioned run inspection and
retired-generation preview/drop remain embedded because their supported reports must
interpret the persisted run and compatible read-contract references through the exact
validated catalog. Destruction follows the ordinary preview/`--force` pattern and the
library rechecks relation identity and dependencies under its final lock. A command
never substitutes inferred DDL or private Kiroku SQL for a missing owner API.


Timer reason inspection and bounded dead-state listing belong to `Keiro.Timer`.
`TimerInspection` preserves `TimerRow` compatibility while returning the full
nullable stored reason. Listings combine exact owner and literal reason filters,
return at most 100 rows, and continue exclusively in database UUID order. A page
is an observation of current eligibility, not a snapshot across requests or an
execution claim. The row limit does not promise bounded search cost. Application
adapters own payload decoding and fresh authorization before rendering, including
following storage continuation past pages emptied by authorization. Neither the
owner label nor an observed reason grants permission. Later guarded mutations
must independently revalidate their guards; the read API does not reserve work.

The HTTP front end follows this same command boundary under
[ADR-53](0053-the-http-operational-surface-is-a-transport-over-the-ops-command-tree.md).
A DLQ read that reserves rows is a mutation even when its command is named `read`.


Workflow inspection belongs to `Keiro.Workflow.Inspection`: at most 500 rows
in immutable key or creation order, with a database observation clock and
library-minted kind/owner/generation-bound cursors. The seven status classes
partition stored status, attempt, and wake columns. Pure owning-library
validation lets HTTP reject invalid page/cursor input before admission and
schema scans; reads repeat validation for direct callers. CLI and HTTP share
the canonical encoders. Header inspection performs only the instance read;
legacy whole reads may drain pages. Matching index and runtime write-cost
evidence remains required before automatic feed or release acceptance.

The owning instance module also exposes a bounded conditional header session.
It compares an exact image of every header field in the current database
snapshot before allowing reuse of pure presentation. The image includes lookup
identity; an image from another identity cannot establish equality. UTC day
and seconds-of-day components preserve BC and distant fractional timestamps
without epoch rounding. Infinity values preserve the existing binary decoder's
Int64-microsecond interpretation, verified against the ordinary lookup. The key is opaque: transaction ids, hashes and wall
clocks are not substitutes for exact field equality. No writer SQL or legacy
lookup contract changes. Transport presentation reuse remains in ops, without
HTTP dependencies in the library.

Page producers reject required continuations that exceed the shared 4096-byte
codec limit. A stored key can be larger than a valid input cursor; such a page
returns a typed result-size failure instead of an unusable or truncated token.
The transport maps this failure to HTTP 413 using the same structured ops code.

Inspection indexes preserve the ordinary writer key domain. Adding columns or
reversing text-key order can exceed PostgreSQL's index-tuple limit for a row
accepted by the existing primary key. The unreleased workflow page indexes
therefore cover keys up to 2600 database-encoded bytes. Wider keys remain valid
runtime inputs and use a fixed-width class/name-hash/id-hash access path. Full
text is rechecked; hashes never become workflow identity or cursor content.
The same statement budgets the raw class/name candidate population before
cursor/time filtering, merges at most 64 exceptional candidates, and caps their
combined key bytes at 256 KiB. Exceeding that budget fails explicitly rather
than omitting rows or widening ordinary writer constraints.

Owner-only child and awakeable indexes do not bound page sorting at a large
owner. The compound-index experiment both exceeds the preliminary write-latency
threshold and rejects valid large owner/child keys. Those detail shapes remain
manual reads with host SQL/read deadlines, outside automatic feeds. Their row
caps are cardinality bounds, not a claim that every owner lookup scans only one
page. Matching read plans, key-domain compatibility and write costs are all
required when choosing any later index.

Aggregate inspection is an explicit application catalog over
`Keiro.Inspection.Aggregate`. Its display encoders are application-owned; ops
and HTTP reuse the library's JSON rather than adding transport SQL. State uses
the shared command hydration algorithm with diagnostics enabled only for the
inspection continuation. Folded state carries its own version; the separately
observed stream head and snapshot clock are not an atomic-view promise. Stream
listing consumes one public Kiroku raw page and advances from the last examined
raw row even when every display item is rejected. Raw history remains Kiroku's.

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
- A destructive execution flag authorizes reaching the owning library operation; it
  does not turn a conditional operation into an unconditional one. PGMQ DLQ purge
  therefore refuses hidden rows even under `--force`.
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
  [ADR 40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
  sanctions the browser-reachable inspection surface as a bounded exception to
  the no-UI stance under exactly this discipline.
- Application-provisioned schema generations do not transfer schema authorship to
  Keiro. Keiro owns orchestration evidence and safe destructive previews; the
  application remains responsible for DDL meaning and compatibility validation.
- `rebuild versioned start|resume|abandon` and `rebuild drop-retired` are mutations;
  status and retired listing are read-only. The CLI's structured reports are renderings
  of `ProjectionCatalogOperations`, not a second lifecycle implementation.


## References

- [MasterPlan 31](../masterplans/31-build-the-keiro-ops-operational-cli.md)
  coordinates the operational CLI initiative.
- [ExecPlan 206](../plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md)
  establishes the package, safety rails, and first command domains.
- [ExecPlan 214](../plans/214-adopt-kiroku-s-durable-subscription-checkpoint-inventory.md)
  adopts Kiroku's released durable inventory and defines the position-distance
  operator and telemetry surfaces.
- [ExecPlan 117](../plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md)
  defines visibility-safe DLQ archive and purge behavior.
- [ADR 0032](0032-catalog-fingerprints-are-canonical-and-rebuild-lifecycle-identity-is-slice-scoped.md)
  defines the catalog adoption preview, transaction, and compiled-catalog
  capability boundary.
- [ADR 0033](0033-consistency-waits-target-reachable-visible-heads.md) separates
  the authoritative append counter from reachable wait and distance targets.
- [ADR 0034](0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
  defines the application-provisioner and Keiro-orchestration boundary for online
  schema-changing projection rebuilds.
- [ExecPlan 275](../plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md)
  records workflow page, write-cost, key-domain and manual-query evidence.

Application-owned `processManagers` hooks mount `pm show` and `pm list`, wrapping
`Keiro.ProcessManager.Inspect`. Database-only `timer pending list`, `shard list`
and detailed `shard status` wrap their owning timer/shard reads. The HTTP app
uses the same grammar and encoders. No adapter adds SQL or derives event-store
identity from private tables. Adding the hook requires applications that build
AppHooks records directly to supply the optional field; `emptyAppHooks` leaves
it unmounted.
