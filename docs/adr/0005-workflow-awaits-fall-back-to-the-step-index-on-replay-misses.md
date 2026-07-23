# 5. Workflow awaits fall back to the step index on replay misses

Date: 2026-07-23

Status: Accepted


## Context

Keiro durable workflows replay a generation into an in-memory map from step
name to JSON result. A workflow snapshot can seed that map at a recorded stream
version, after which hydration reads only later journal events. This is an
advisory optimization: the append-only journal remains the persisted history.

A wake source such as an awakeable signal, child completion, or fired sleep can
append a result while the owning workflow run is still executing. If that run
then writes a snapshot at a later stream version, its in-memory map does not
contain the concurrent wake result even though the result's journal event is at
or below the snapshot version. The snapshot seed plus exclusive tail read then
under-approximates the journal indefinitely. An `awaitStep` map miss previously
armed the wake source and suspended without appending anything, so it had no
way to converge on the already-recorded result.

ADR 3, `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`,
governs whether a snapshot was encoded under compatible state and fold
assumptions. Compatibility does not establish that a workflow snapshot
contains every concurrent journal write covered by its version, so this
concurrency invariant needs a separate decision.


## Decision

The generation-scoped `keiro.keiro_workflow_steps` index is the authoritative
point lookup for whether a workflow step has already been journaled. Every
journal append records the corresponding index row in the same transaction, so
the index is complete whenever the append is visible.

When `awaitStep` misses the in-memory replay map, the workflow interpreter
queries that index before checking cancellation, running the arming action, or
suspending. On an index hit it inserts the stored value into the in-memory map,
records a replay metric, and decodes and returns the value exactly like an
ordinary replay hit. On an index miss the existing cancellation, arm, and
suspend path remains unchanged.

The fallback is generation-scoped. A prior generation's result must never
resolve an await in a later generation.

The fallback applies only to `awaitStep`. A normal `step` or patch miss attempts
an append; the append transaction rechecks the same index under the step lock
and adopts an already-recorded value, so those operations already converge
without an additional read.


## Consequences

- Workflow snapshots may remain advisory, compact replay seeds without
  coordinating every concurrent wake writer or invalidating snapshots.
- Awakeables, child completions, and sleeps cannot be hidden permanently by a
  snapshot or by a stale same-run map.
- A genuinely unresolved await performs one indexed point read before arming
  and suspending. The query is confined to the miss path and does not add work
  to normal step execution or replay hits.
- A recorded wake result has settled-history semantics: it is delivered before
  a pending cancellation check, matching the ordinary in-memory replay path.
- Correctness now explicitly depends on all workflow journal append paths
  maintaining `keiro_workflow_steps` in the same transaction. New append paths
  must preserve that invariant.
