# Roadmap: conditional reads on the keiro-pgmq worker path

Status: roadmap, not scheduled. Captured 2026-06-13 while scoping MasterPlan
`docs/masterplans/10-keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability.md`,
which deliberately excludes this item (see that plan's Decision Log).

## What this is

PGMQ's `read` (and `read_with_poll`) accept a `conditional jsonb DEFAULT '{}'` parameter
that filters returned messages by JSONB containment against the **message body**
(`message @> conditional`); an empty `{}` disables the filter. This lets a worker selectively
consume only messages whose payload matches a predicate — for example, a single physical
queue partitioned by a `kind` field where different worker fleets each read only their kind.
The capability is marked experimental upstream ("API subject to change") and has no GIN index
on the body by default, so heavy use causes sequential scans unless an index is added.

In `pgmq-hs` this is already modeled: `Pgmq.Hasql.Statements.Types.ReadMessage` and
`ReadWithPollMessage` both carry `conditional :: !(Maybe Value)`, and the `Pgmq` effect
threads it through. keiro-pgmq's own one-shot drain already constructs `ReadMessage { …,
conditional = Nothing }` (`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, `runJobOnceWithContext`), so the
*drain* path could support conditional reads with no external change.

## Why it is deferred

The blocker is the **worker** path. `shibuya-pgmq-adapter` builds its reads in
`Shibuya.Adapter.Pgmq.Internal` (`mkReadMessage`, `mkReadWithPoll`) with `conditional`
**hard-coded to `Nothing`**, and `PgmqAdapterConfig` exposes no field to override it. So
enabling conditional reads on `runJobWorkers`/`jobProcessor` requires:

1. A change in the separate repository `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`:
   add a `conditional :: Maybe Value` (or a typed predicate) field to `PgmqAdapterConfig`,
   thread it into `mkReadMessage`/`mkReadWithPoll`, and ship a new `shibuya-pgmq-adapter`
   version. Note the **grouped** read paths (`read_grouped`/`read_grouped_rr`) have no
   `conditional` parameter at the PGMQ layer at all (it was removed from grouped reads in
   pgmq 1.9.0), so conditional + FIFO ordering is not expressible even upstream.
2. A version-pin bump of `shibuya-pgmq-adapter` in the keiro repo (`keiro-pgmq.cabal`'s
   `>=0.7 && <0.8` bound) once that release exists.
3. keiro-pgmq-side surface: a `conditional` filter on `JobTuning` (or a new field) mapped into
   `adapterConfigFor`, plus the same on the drain path.

No current keiro consumer needs payload-filtered consumption, and the cross-repo coordination
cost is real. When a concrete need appears, author a fresh ExecPlan from this sketch: do the
shibuya-pgmq-adapter change first, then the pin bump, then the keiro-pgmq surface, and add a
GIN-index-on-body provisioning option (relates to MasterPlan #10's EP-2 provisioning surface)
so filtered reads do not seq-scan.

## Drain-path-only alternative

If only the one-shot `runJobOnce`/`runJobOnceWithContext` cadence needs filtering, that path
reads directly against the `Pgmq` effect and could expose `conditional` with **no** shibuya
change — a much smaller, self-contained ExecPlan. This is the recommended first step if a need
arises before anyone wants worker-path filtering.
