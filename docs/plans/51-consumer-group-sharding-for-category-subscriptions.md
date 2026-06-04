---
id: 51
slug: consumer-group-sharding-for-category-subscriptions
title: "Consumer-group sharding for category subscriptions"
kind: exec-plan
created_at: 2026-06-03T21:28:37Z
intention: "intention_01kt7npy22e5tb3ybycsgeqdnm"
master_plan: "docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md"
---

# Consumer-group sharding for category subscriptions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today a keiro deployment that wants to keep up with a very busy event category — say
`orders`, producing thousands of events a second across millions of order streams —
runs **one** subscription worker. That single worker reads the category's events in
order and hands each to a process manager or projection handler. When the handler
cannot keep up, the worker falls behind and the backlog grows without bound. The v1
answer to "scale this out" is: split the category across `N` cooperating workers, each
taking a disjoint slice of the keyspace, so total throughput is roughly `N×` a single
worker. The substrate for that split — kiroku's **consumer groups** — already exists
(see Context). What is missing is the part that makes it *operable*: a way for a pool
of identical worker processes to agree, without a human hand-assigning slot numbers,
on **who owns which slice right now**, and to **re-divide the slices automatically**
when a worker joins, leaves, or dies.

After this change a user can start the *same* worker binary `N` times — on `N` hosts,
in `N` containers, in an autoscaling group — pointed at one subscription name, and the
workers will cooperatively partition the category among themselves: every event in the
category is processed by exactly one worker, no event is processed twice, and no event
is skipped. If a worker is killed, the events it was responsible for are picked up by a
surviving worker within a bounded number of seconds (its **lease** expires and another
worker claims its slices). The user does this with no external coordinator (no etcd, no
ZooKeeper, no Consul) — the coordination lives entirely in Postgres tables that keiro
already owns.

**How you can see it working.** The acceptance test (Milestone 5) starts three worker
processes against a category seeded with events on many distinct streams, lets them
drain it, and asserts three observable facts: (1) the per-worker processed-event counts
**sum to exactly the total** number of events; (2) **no stream-key is processed by two
different workers** (disjoint ownership — no duplicate work); and (3) after one worker
is **killed mid-drain**, the streams it owned are re-claimed and drained to completion
by a surviving worker once the dead worker's lease expires (failover). All three are
checked by reading rows a test handler writes, not by inspecting internal state.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (keiro-side, schema): add the `keiro_subscription_shards` migration with the
      `SET search_path TO kiroku, pg_catalog;` header (plan 46 convention) and the `embedDir`
      touch-comment bump in `Keiro/Migrations.hs`. (2026-06-03; shipped as
      `2026-06-05-01-00-00-keiro-subscription-shards.sql` — timestamped after EP-48's
      `2026-06-05-00-00-00` generation migration, which landed after this plan was written.)
- [x] Milestone 1: prove the migration applies (table + indexes exist in `kiroku` schema).
      (2026-06-03; applies clean in the suite migration list; the M2 unit test reads/writes it.)
- [x] Milestone 2 (keiro-side, lease API): add `Keiro.Subscription.Shard.Schema` (the SQL
      statements `ensureShardRows` / `claimShardsTx` / `renewLeaseTx` / `releaseShardsTx` /
      `listShardOwnership`) and `Keiro.Subscription.Shard` (the `ShardLease`, `WorkerId` types,
      `acquireOwnedBuckets`, `renewOwnedBuckets`, `relinquish`, `ensureShards`,
      `ownershipSnapshot`, `fairShareTarget`). (2026-06-03; expiry is folded into the claim
      predicate `lease_expires_at < now`, so no separate `expireStaleLeasesTx`.)
- [x] Milestone 2: unit-test the claim/renew/expire SQL against a real Postgres (disjointness
      and lease-expiry behaviour at the SQL level, no workers yet). (2026-06-03; 6 examples.)
- [x] Milestone 3 (keiro-side, rebalance loop): add `Keiro.Subscription.Shard.Worker`
      (`ShardedWorkerOptions`, `reconcileShardsOnce`, `runShardedSubscriptionGroup`) that on each
      pass claims a fair share of buckets (one per pass), renews held leases, sheds excess, and
      (re)spawns one kiroku consumer-group reader per owned bucket. (2026-06-03.)
- [x] Milestone 3: prove a single process with `N=4` buckets drains a seeded category.
      (2026-06-03; one worker drains 40 events across 8 streams exactly once, `maxW == 1`.)
- [x] Milestone 4 (upstream surface): forward the kiroku/shibuya asks to
      `docs/research/11-upstream-roadmap.md` — **§4.12** (dynamic-membership / owned-bucket-set
      consumer group) and **§6.2** (shard-aware supervised non-adapter worker). (2026-06-03;
      §4.11 was already taken by EP-50's store-wake combinator, so EP-51 used the next number §4.12.)
- [x] Milestone 5 (failover acceptance): multi-process disjoint-drain + kill-a-worker
      failover test; assert counts sum to total, no key processed twice, killed worker's
      buckets re-drained after lease expiry. (2026-06-03; 3 workers, `N=6`, converge → drain
      disjointly → kill one → re-home + drain new events; stable across repeated runs.)
- [x] Milestone 6 (optional, soft-dep on EP-50): EP-50 has landed, but its `Keiro.Wake` channel
      wakes on event *appends* (`kiroku.events`), not shard ownership *changes*. The polled loop
      is the shipped default; the seam (the single inter-pass `threadDelay`, swappable for a
      bounded wait on a dedicated `keiro_shard_rebalance` NOTIFY) is documented on
      `runShardedSubscriptionGroup`. Latency-only; correctness does not depend on it. (2026-06-03.)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-06-03: **The naive `liveWorkers` estimate makes a cold-start monopolist, which
  the plan's claim-up-to-fair-share design cannot recover from.** The plan estimates
  `liveWorkers` as "distinct non-expired owners + self" and claims up to
  `ceil(N/liveWorkers)`. But a worker that owns *nothing* is invisible in that count, so
  the first worker to run (seeing `liveWorkers = 1`, target `= N`) grabs every bucket, and
  then on every later pass still sees only itself (`liveWorkers = 1`) — it never sheds, and
  the idle peers starve forever. The first failover-acceptance run timed out at the
  `waitShardsBalanced` gate (15 s) for exactly this reason. **Fix: claim one bucket per
  pass.** Concurrently-starting workers then each grab one bucket on pass 1, become visible
  in the lease table, and climb to an even share together (with the shed step cleaning up any
  residual imbalance); `acquireOwnedBuckets` now caps the claim to 1 and documents why.
  Ownership spreads over up to `N` reconcile intervals — a deliberate trade of spin-up
  latency for coordinator-free fairness. After the fix the acceptance test converges and
  drains in ~4 s and is stable across repeated runs.
- 2026-06-03: **No separate `expireStaleLeasesTx` is needed — expiry *is* the claim
  predicate.** A claim takes any row where `owner_worker_id IS NULL OR lease_expires_at < now`,
  so an expired lease is reclaimed by the ordinary claim path. Failover therefore needs no
  sweeper: a dead worker simply stops renewing, and the next survivor's claim pass picks up its
  buckets once the lease lapses (proven by the M5 kill-a-worker test).
- 2026-06-03: **The worker is `IO`-shaped, not `Eff es`, and its handler is a plain
  `RecordedEvent -> IO ()`** — the same call the EP-50 push worker
  (`runWorkflowResumeWorkerPush`) made, for the same reason: it manages long-lived
  `Control.Concurrent` reader threads and the `KirokuStore` handle directly. The plan sketched
  `reconcileShardsOnce`/`runShardedSubscriptionGroup` with `Eff es` + `Handler es RecordedEvent`
  signatures; the as-shipped surface is `IO` with `runStoreIO` per lease pass and one
  `forkIO`-managed `subscriptionStream` drain per owned bucket. A sharded subscription is
  at-least-once across a rebalance handoff, so the handler must be idempotent (keyed on
  `eventId`) — exactly the existing async-projection contract; the acceptance test's sink is
  `INSERT ... ON CONFLICT (event_id) DO NOTHING`.
- 2026-06-03: **`WorkerId` lives in `Keiro.Subscription.Shard.Schema`** (re-exported from
  `Keiro.Subscription.Shard`), not in `Shard.hs` as the plan listed, so the lower SQL module can
  name it in its statement signatures without an import cycle.
- 2026-06-03: **kiroku subscriptions do not hold a pooled connection for their lifetime** —
  the worker loop acquires a connection per query (`Pool.use` per read-batch / checkpoint
  save) and releases it, and the ack-coupled bridge blocks the handler reply while holding
  *no* connection. So `N` concurrent bucket readers do not each pin a connection; the default
  pool of 10 comfortably hosts the 3-worker / 6-bucket acceptance test (no deadlock, no
  starvation). This is the sharding analogue of EP-50's "push adds zero connections" finding.
- 2026-06-03: **Upstream numbering: §4.11 was already taken by EP-50.** The plan named §4.11 for
  the dynamic-membership consumer-group ask, but EP-50 had already claimed §4.11 (the store-wake
  combinator). EP-51's asks therefore landed at **§4.12** (kiroku) and **§6.2** (shibuya).


## Decision Log

Record every decision made while working on the plan.

- Decision: Build sharding on kiroku's **existing consumer-group partitioning**, not on a
  new partition mechanism. EP-51 adds only the *cooperative ownership / leadership* layer
  on top.
  Rationale: While researching this plan I found kiroku already ships the entire "partition a
  category into N buckets by a stable hash of the stream key" mechanism. `Kiroku.Store.Subscription.Types.ConsumerGroup { member :: Int32, size :: Int32 }`
  (`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/Types.hs`)
  selects, in SQL, only the events whose originating stream hashes to one bucket via
  `(((hashtextextended(s.stream_id::text, 0) % size) + size) % size) = member`
  (`readCategoryForwardConsumerGroupStmt`, `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/SQL.hs:785,828`).
  Per-member checkpoints are already keyed `(subscription_name, consumer_group_member)`
  (`getCheckpointMemberStmt`/`saveCheckpointMemberStmt`, same file). The shibuya adapter
  already exposes it (`Shibuya.Adapter.Kiroku.kirokuConsumerGroupProcessors`,
  `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`).
  What the substrate does **not** provide is dynamic membership: its docstring states
  "Exactly one live process must own each member index at a time" and the assignment is a
  manual `[0..N-1]` wiring. EP-51 is exactly the missing operability layer, so reusing the
  partition predicate is both simpler and matches the MasterPlan's "Postgres-native,
  library-shaped" thesis. The MasterPlan's "the subscription worker and ownership" Integration
  Point names EP-51 owner of the sharded-ownership table and the leadership/claim protocol —
  this decision keeps that scope while not reinventing partitioning.
  Date: 2026-06-03.

- Decision: A **bucket is a kiroku consumer-group member index** in `[0, N)`. We do not
  introduce a second hashing scheme.
  Rationale: kiroku's `member_of(stream_id)` predicate is the bucket boundary already; if
  keiro hashed stream keys independently the two partitions could disagree and an event would
  fall into a keiro bucket no worker reads from. Defining "bucket = member index" makes the
  keiro ownership table and the kiroku fetch predicate share one source of truth. `N` (the
  bucket count) is fixed per subscription name at deploy time, exactly as kiroku's `size`
  is fixed; rebalancing changes *who owns* buckets, never *how many* buckets exist.
  Date: 2026-06-03.

- Decision: Cooperative ownership uses a **lease (heartbeat timestamp) row per bucket**, not
  a held advisory lock.
  Rationale: MasterPlan 5 established (and `Keiro.Workflow.Resume.WorkflowResumeOptions.useAdvisoryLock`
  documents at `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Resume.hs:130-143`)
  that a *transaction-scoped* advisory lock (`pg_try_advisory_xact_lock`) auto-releases at
  transaction end and so cannot be held across a multi-transaction run, and a *session-scoped*
  lock has no connection affinity through kiroku's pooled `Store`. kiroku's own consumer-group
  guard (`guardMember`, `Kiroku.Store.Subscription.Worker`) is documented as a startup
  *detection probe only*, not a lifetime-held lock. A lease — an owner id plus a renewable
  `lease_expires_at` timestamp written to an ordinary table row, claimed and renewed inside
  short transactions — gives lifetime ownership and automatic failover (a dead owner stops
  renewing; its lease expires; another worker claims the bucket) without depending on
  connection affinity. This is the same pattern keiro's timer worker already trusts
  (`FOR UPDATE SKIP LOCKED` claim + status flip) generalised to a renewable lease.
  Date: 2026-06-03.

- Decision: **Reject an external coordinator** (etcd / ZooKeeper / Consul) for leadership.
  Rationale: the parent MasterPlan's Vision & Scope and `docs/research/10-workflow-roadmap.md`
  §6 ("Avoid") are explicit that Akka's cluster-sharding is "gorgeous in Scala/Akka and a
  nightmare to operate", and the whole keiro thesis (`docs/research/10-workflow-roadmap.md`
  §8 positioning statement) is "workers are OS processes that connect to Postgres" with no
  separate cluster to run. An external coordinator would reintroduce exactly the operational
  tax v1 rejects. Postgres already holds the events, the checkpoints, and the timers; the
  lease table lives there too. The cost is that lease liveness is bounded by a poll interval
  rather than a push (mitigated by the EP-50 soft-dep in Milestone 6), which is an acceptable
  few-seconds failover latency for a throughput feature.
  Date: 2026-06-03.

- Decision: **Reject a session-advisory-lock-across-transactions** design for ownership.
  Rationale: same MasterPlan 5 finding as the lease decision above — it is the specific
  mechanism that does not work through kiroku's pooled `Store`. Recorded as its own line so
  a future contributor does not "simplify" the lease back into a session lock.
  Date: 2026-06-03.

- Decision: Scope split — the **dynamic-membership ownership/lease/rebalance layer is
  keiro-side** and ships in this plan; the **only upstream asks are quality-of-life**, not
  blockers, and are forwarded to `docs/research/11-upstream-roadmap.md`.
  Rationale: kiroku's consumer-group partition + per-member checkpoint is sufficient to build
  N disjoint readers from keiro today (a keiro worker just opens a `kirokuAdapter` with
  `consumerGroup = Just (ConsumerGroup m N)` per owned bucket). So nothing upstream blocks the
  feature. The two upstream items that would make it *nicer* — a kiroku consumer-group variant
  that takes a dynamic owned-bucket *set* in one subscription (vs one adapter per bucket), and
  a shibuya supervised non-adapter worker entry point to host the rebalance loop with free
  spans — are forwarded (as §4.12 and §6.2) but not depended on. This matches the MasterPlan's
  requirement that each Wave-2 plan "state precisely which part of the contract is keiro-side
  and which requires an upstream change, and forward the upstream part".
  Date: 2026-06-03.

- Decision: A worker **claims at most one bucket per reconcile pass**, rather than its whole
  fair share at once.
  Rationale: claiming the full fair share lets the first worker to run (which sees
  `liveWorkers = 1`, hence target `= N`) monopolise every bucket before its peers' first pass;
  because a worker owning nothing is invisible in the lease table, the monopolist then never
  detects the idle peers and never sheds, and they starve. Claiming one bucket per pass means
  concurrently-starting workers each take one, become visible after pass 1, and converge to an
  even split together. The cost is that ownership spreads over up to `N` reconcile intervals
  on a cold start — acceptable for a throughput feature, and the shed step still corrects any
  residual imbalance from staggered joins. (Discovered via the first M5 timeout; see
  Surprises.) A bulk-claim variant is forwarded implicitly by the §4.12 owned-bucket-set ask.
  Date: 2026-06-03.

- Decision: The worker is **`IO`-shaped** (`runShardedSubscriptionGroup :: KirokuStore -> … -> IO ()`)
  with a plain **`RecordedEvent -> IO ()` handler**, not `Eff es` + a shibuya `Handler`.
  Rationale: it manages long-lived `Control.Concurrent` reader threads and the `KirokuStore`
  handle directly (one `forkIO` `subscriptionStream` drain per owned bucket, `runStoreIO` per
  lease pass), exactly like EP-50's `runWorkflowResumeWorkerPush`. The plan's `Eff es`/`Handler`
  sketch was adapted to this shape; the lease layer (`Keiro.Subscription.Shard`) stays effectful
  and is the testable unit. Recorded so a future contributor does not "restore" the `Eff` shape
  and reintroduce the thread-management awkwardness.
  Date: 2026-06-03.

- Decision: The migration is timestamped **`2026-06-05-01-00-00`**, not the plan's
  `2026-06-03-03-00-00`.
  Rationale: EP-48 (continue-as-new) landed its `2026-06-05-00-00-00-keiro-workflow-generation.sql`
  migration after this plan was written, so the plan's proposed timestamp would have sorted
  *before* it. Migrations must be timestamped after the latest existing one, so EP-51 uses
  `2026-06-05-01-00-00`.
  Date: 2026-06-03.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**Complete (2026-06-03).** EP-51 delivers exactly the operability layer the Purpose named: a
user can start the same worker binary `N` times against one `SubscriptionName` and the workers
cooperatively partition a category — every event handled by exactly one worker, none twice,
none skipped — with automatic failover when a worker dies, and no external coordinator (only
Postgres). The acceptance test demonstrates all three Purpose facts off a sink table: three
workers drain a category disjointly (`maxW == 1`, counts sum to total, ≥ 2 workers
participated), then a killed worker's buckets are re-homed via lease expiry and the new events
drain (`count == total1 + total2`), with no duplicate `eventId` (PK + idempotent sink).

What shipped, against the plan:

- **Storage** (`keiro_subscription_shards`) and **lease API**
  (`Keiro.Subscription.Shard{,.Schema}`) shipped as designed: a renewable
  `lease_expires_at` per `(subscription_name, bucket)`, claimed with `FOR UPDATE SKIP LOCKED`,
  never a held lock — the resume worker's documented reason.
- **Rebalance worker** (`Keiro.Subscription.Shard.Worker`) shipped, with two adaptations from
  the plan sketch (both in the Decision Log): the worker is `IO`-shaped with a
  `RecordedEvent -> IO ()` handler (matching EP-50), and claims **one bucket per pass** so a
  worker pool converges to a fair split without a monopolist — the single most important
  implementation insight (see Surprises).
- **Upstream** asks forwarded as §4.12 (owned-bucket-set consumer group) and §6.2 (shard-aware
  supervised worker); neither blocks the feature, confirming the MasterPlan's revised "Wave-2
  is not upstream-blocked" finding.
- **Milestone 6** left as the polled default; the EP-50 wake channel signals appends, not
  ownership changes, so the rebalance-NOTIFY swap is documented as a one-`threadDelay` seam, not
  wired (latency-only, correctness-independent).

Gaps / follow-ups: (1) cold-start spread takes up to `N` reconcile intervals (the one-per-pass
trade); the §4.12 owned-bucket-set variant would also enable faster bulk claims. (2) A
voluntarily-joining worker only picks up buckets freed by expiry, not by proactive stealing
from an over-provisioned peer — fine for the failover acceptance, a possible future
rebalance-on-join refinement. (3) The `keiro_shard_rebalance` push signal (M6) is a clean
latency win left for whenever interactive rebalance latency matters.

Acceptance: `cabal build all` clean; `cabal test keiro` 150/0 (+8: 6 lease, 1 single-worker
drain, 1 disjoint-drain + failover); failover test stable across repeated runs.


## Context and Orientation

This section assumes you have never seen this repository. Read it in full before editing.

### What keiro is

keiro is a Haskell, Postgres-native, library-shaped event-sourcing and workflow engine. It
sits on top of three sibling libraries: **kiroku** (the Postgres event store, at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`), **keiki** (the pure functional core),
and **shibuya** (a supervised-worker substrate, at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`). keiro's own source lives under
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/`; its database migrations live under
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/`. There is no server to run — a keiro
"worker" is an ordinary OS process that opens a connection pool to Postgres.

### Terms of art (defined in plain language)

- **Category subscription.** A *subscription* is a long-lived loop that reads events out of
  the event store in order and calls a handler for each. A *category* is a named family of
  related streams: kiroku derives a stream's category from its name using the Eventide
  convention `<category>-<id>` — everything before the first `-`. So all streams named
  `orders-<uuid>` belong to category `orders`. A *category subscription* therefore reads, in
  order, every event written to any stream in that category, and is the engine that drives
  process managers and async projections. In keiro the handler is bridged through the
  shibuya-kiroku-adapter (`Shibuya.Adapter.Kiroku.kirokuAdapter`).

- **Stream key.** The identity of one event stream (e.g. one order). kiroku stores each stream
  under a surrogate integer id `stream_id`. All events for one stream key are strictly ordered
  and must be processed by one worker so that order is preserved.

- **Bucket (a.k.a. partition / consumer-group member).** One of `N` disjoint slices of a
  category's keyspace. A stream key is assigned to exactly one bucket by a stable hash of its
  id, namely kiroku's
  `bucket = (((hashtextextended(stream_id::text, 0) % N) + N) % N)`, a number in `[0, N)`.
  Because the hash is stable, every event for a given stream always lands in the same bucket,
  so a worker that owns bucket `b` sees a complete, in-order slice of the category and never
  shares a stream with another worker. "Bucket" and "kiroku consumer-group member index" are
  the same thing in this plan (see Decision Log).

- **Lease.** A time-bounded claim of ownership over a bucket, recorded as a database row
  carrying the owning worker's id and an expiry timestamp. A worker *renews* its lease
  periodically (writes a fresh expiry) to keep it; if it stops renewing (it crashed, was
  killed, or partitioned away), the lease *expires* and the bucket becomes claimable by
  another worker. This gives automatic failover without any held lock or external coordinator.

- **Rebalance.** Re-dividing the buckets among the currently-live workers when membership
  changes (a worker joins, a worker's lease expires, or a worker voluntarily relinquishes).
  After a rebalance, each live worker owns a fair (near-equal) share of the `N` buckets, every
  bucket is owned by exactly one worker, and ownership is disjoint.

- **Worker id.** A per-process unique id (a UUID minted at process start) that names the owner
  in a lease row. Two restarts of the same binary get two different worker ids — a restarted
  process does not inherit the dead process's leases; it claims afresh after the old leases
  expire.

### The substrate this plan extends (read these files)

The single most important discovery is that **kiroku already implements bucketed partitioning
and per-bucket checkpoints**. EP-51 does not build partitioning; it builds the *ownership* layer
on top. Concretely:

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/Types.hs`
  defines `data ConsumerGroup = ConsumerGroup { member :: Int32, size :: Int32 }` and the
  `consumerGroup :: Maybe ConsumerGroup` field on `SubscriptionConfigM`. With
  `consumerGroup = Just (ConsumerGroup m n)`, a subscription reads only events whose stream
  hashes to bucket `m` of `n`. The validity invariant (`size >= 1`, `0 <= member < size`) is
  enforced by `subscribe` (throws `InvalidConsumerGroup`).

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/SQL.hs`
  (lines ~785–870) holds `readCategoryForwardConsumerGroupStmt` and
  `readAllForwardConsumerGroupStmt`: the partition predicate
  `(((hashtextextended(...::text, 0) % $size) + $size) % $size) = $member`. Checkpoints are
  per-member: `getCheckpointMemberStmt` / `saveCheckpointMemberStmt` key on
  `(subscription_name, consumer_group_member)`, so each bucket resumes from its own position.

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`
  runs the worker loop. Group members use `liveLoopDbDriven` (re-query on global-position
  advance) because the per-category NOTIFY signal cannot be cheaply replicated for a hashed
  partition. It also has `guardMember` — a **startup-only** `pg_try_advisory_xact_lock`
  conflict probe (lines ~345–369) whose own comment says it "does NOT hold the lock for the
  worker's lifetime". This confirms there is no lifetime-held lock today: ownership is by
  operator convention ("exactly one live process per member index").

- `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku/shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs`
  exposes the consumer group to keiro: `kirokuAdapter store cfg` where `cfg.consumerGroup`
  selects the bucket, and `kirokuConsumerGroupProcessors store groupCfg handler` which yields
  `groupSize` named processors (one per bucket) **all in one process**. Its docstring states
  the gap EP-51 fills: "To run members across separate processes instead, give each process one
  `kirokuAdapter` with its own `member` index ... Exactly one live process must own each member
  index at a time." That "exactly one ... must own ... at a time" is today a manual constraint;
  EP-51 makes it automatic and dynamic.

### How keiro already does claim-and-checkpoint workers (the shape to mirror)

EP-51's lease loop mirrors patterns already in keiro:

- `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Timer.hs` — `runTimerWorkerWith` /
  `runTimerWorker` claim due timer rows with `FOR UPDATE SKIP LOCKED`, fire them, and flip
  status, with a single testable `Eff es (Maybe TimerRow)` pass and a loop driver. Multiple
  timer workers run safely because `SKIP LOCKED` hands disjoint rows to each.
- `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Outbox.hs` — `publishClaimedOutbox`
  claims a batch with `FOR UPDATE SKIP LOCKED` and threads a `Maybe KeiroMetrics` for
  no-op-under-`Nothing` observability. Same single-pass-plus-loop shape.
- `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Workflow/Resume.hs` — the resume worker,
  whose `useAdvisoryLock` field (lines 130–143) is the canonical write-up of *why a session/
  transaction advisory lock cannot be the ownership mechanism through a pooled `Store`*. Read
  it: it is the direct precedent for choosing a lease over a lock.

### Migrations: how to add a table (plan 46 convention)

keiro migrations are versioned `.sql` files under
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/sql-migrations/`, embedded into the
binary by `embedDir "sql-migrations"` in
`/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/src/Keiro/Migrations.hs` and applied via
`codd`. The existing tables (`keiro_snapshots`, `keiro_outbox`, `keiro_inbox`, `keiro_timers`,
`keiro_workflow_steps`, `keiro_awakeables`, `keiro_workflow_children`) all use
`CREATE TABLE IF NOT EXISTS`. Two hard rules carried in from plan 46
(`docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md`)
and the MasterPlan's "Migrations" Integration Point:

1. **Self-set the search path.** Each migration must begin with
   `SET search_path TO kiroku, pg_catalog;` so the table lands in the `kiroku` schema even
   when codd resumes a ledger in a default-`public` session. (The bootstrap's `SET` is not
   re-run on incremental upgrades, so every later migration must set it itself.)
2. **Touch the `embedDir` comment.** Adding a new `.sql` file does not always retrigger GHC
   recompilation of `Keiro/Migrations.hs` (`embedDir` is not tracked per-file). Edit the
   touch-comment at the bottom of that module (it lists the current file set) so the new
   migration is embedded; if in doubt run `cabal clean` for the `keiro-migrations` package.


## Plan of Work

The work is six milestones. Milestones 1–3 and 5 are **keiro-side** and ship the feature.
Milestone 4 is the **upstream surface** (documentation forwarding, no upstream code is
required to ship). Milestone 6 is an **optional** EP-50 soft-dependency. Each milestone is
independently verifiable.

### Milestone 1 — the ownership table (keiro-side)

Scope: add the durable lease table. At the end, the database has a `keiro_subscription_shards`
table in the `kiroku` schema with the right columns and indexes; nothing reads or writes it
yet.

Create `/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/sql-migrations/2026-06-03-03-00-00-keiro-subscription-shards.sql`
(timestamped after the latest existing migration, `2026-06-03-02-00-00-keiro-workflow-children.sql`):

```sql
-- The keiro_subscription_shards table: cooperative ownership of category
-- subscription buckets (EP-51).
--
-- A "bucket" is a kiroku consumer-group member index in [0, shard_count): the
-- stream key (originating stream_id) hashes to one bucket via
--   (((hashtextextended(stream_id::text, 0) % shard_count) + shard_count) % shard_count)
-- exactly as kiroku's readCategoryForwardConsumerGroupStmt does. This table does
-- NOT re-hash anything; it records WHO owns each bucket right now, as a renewable
-- lease. A live worker renews lease_expires_at on a heartbeat; a dead worker stops
-- renewing, its lease expires, and another worker re-claims the bucket (failover).
--
-- One row per (subscription_name, bucket). owner_worker_id NULL means unowned
-- (free to claim). The journal/checkpoints stay in kiroku's `subscriptions` table
-- keyed (subscription_name, consumer_group_member); this table only governs
-- assignment, never event position.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_subscription_shards (
  subscription_name  TEXT        NOT NULL,
  bucket             INT         NOT NULL,        -- kiroku consumer-group member index
  shard_count        INT         NOT NULL,        -- N; fixed per subscription_name
  owner_worker_id    UUID,                        -- NULL = unowned / claimable
  lease_expires_at   TIMESTAMPTZ,                 -- NULL when unowned
  heartbeat_at       TIMESTAMPTZ,                 -- last renewal (observability)
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (subscription_name, bucket),
  CONSTRAINT keiro_subscription_shards_bucket_range_chk
    CHECK (bucket >= 0 AND bucket < shard_count),
  CONSTRAINT keiro_subscription_shards_count_chk
    CHECK (shard_count >= 1)
);

-- Fast lookup of an owner's currently-held buckets (renew path) and of
-- claimable buckets (claim path filters on lease_expires_at).
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_owner_idx
  ON keiro_subscription_shards (subscription_name, owner_worker_id);

-- Find expired/unowned buckets cheaply during a claim sweep.
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_lease_idx
  ON keiro_subscription_shards (subscription_name, lease_expires_at);
```

Then bump the touch-comment in `/Users/shinzui/Keikaku/bokuno/keiro/keiro-migrations/src/Keiro/Migrations.hs`
so the new file is embedded (add `2026-06-03-03-00-00-keiro-subscription-shards.sql` to the
listed set).

Acceptance: applying migrations (see Concrete Steps) creates the table and indexes in the
`kiroku` schema; `\d kiroku.keiro_subscription_shards` shows the columns above.

### Milestone 2 — the lease API (keiro-side)

Scope: the SQL statements and the typed Haskell surface that claim, renew, release, and expire
leases. At the end, a unit test can exercise claim/renew/expire against a real Postgres with no
workers running.

Create `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Subscription/Shard/Schema.hs` holding
the `Hasql.Transaction.Transaction`-flavoured statements (run through kiroku's
`Kiroku.Store.Transaction.runTransaction`, the same primitive the timer/outbox paths use). The
operations, all scoped to one `subscription_name`:

- `ensureShardRows :: SubscriptionName -> Int -> Tx.Transaction ()` — idempotently insert the
  `N` rows `(name, bucket=0..N-1, shard_count=N, owner=NULL)` with
  `ON CONFLICT (subscription_name, bucket) DO NOTHING`. Called once at worker startup so the
  table is fully populated before any claim.

- `claimShardsTx :: SubscriptionName -> WorkerId -> Int -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]`
  — claim up to `targetCount` buckets that are currently unowned **or** whose lease has expired
  (`owner_worker_id IS NULL OR lease_expires_at < now`), in one statement, returning the bucket
  numbers actually claimed. The claim uses
  `SELECT ... FOR UPDATE SKIP LOCKED` over the claimable rows (so two workers racing the same
  bucket cannot both win — `SKIP LOCKED` hands each contended row to at most one), then `UPDATE`s
  the selected rows to set `owner_worker_id = $worker`, `lease_expires_at = $now + $ttl`,
  `heartbeat_at = $now`. Sketch:

  ```sql
  WITH claimable AS (
    SELECT bucket FROM keiro_subscription_shards
     WHERE subscription_name = $name
       AND (owner_worker_id IS NULL OR lease_expires_at < $now)
     ORDER BY bucket
     LIMIT $targetCount
     FOR UPDATE SKIP LOCKED
  )
  UPDATE keiro_subscription_shards s
     SET owner_worker_id = $worker, lease_expires_at = $now + $ttl,
         heartbeat_at = $now, updated_at = $now
    FROM claimable c
   WHERE s.subscription_name = $name AND s.bucket = c.bucket
  RETURNING s.bucket;
  ```

- `renewLeaseTx :: SubscriptionName -> WorkerId -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]`
  — `UPDATE ... SET lease_expires_at = $now + $ttl, heartbeat_at = $now WHERE subscription_name = $name AND owner_worker_id = $worker RETURNING bucket`.
  Returns the buckets still held (a bucket stolen after this worker's lease lapsed will not be
  in the result — that is how a worker learns it lost a bucket).

- `releaseShardsTx :: SubscriptionName -> WorkerId -> [Int] -> Tx.Transaction ()` — graceful
  relinquish: `UPDATE ... SET owner_worker_id = NULL, lease_expires_at = NULL WHERE subscription_name = $name AND owner_worker_id = $worker AND bucket = ANY($buckets)`.
  Called on clean shutdown so a stopped worker's buckets are claimable immediately, without
  waiting for lease expiry.

- `listShardOwnership :: SubscriptionName -> Tx.Transaction [(Int, Maybe WorkerId, Maybe UTCTime)]`
  — observability/test read of `(bucket, owner, lease_expires_at)`.

Create `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Subscription/Shard.hs` with the
typed wrappers and supporting types:

```haskell
newtype WorkerId = WorkerId UUID
  deriving stock (Eq, Ord, Show)

freshWorkerId :: IOE :> es => Eff es WorkerId

data ShardLease = ShardLease
  { subscriptionName :: !SubscriptionName
  , workerId         :: !WorkerId
  , shardCount       :: !Int
  , leaseTtl         :: !NominalDiffTime   -- how long a claim/renew is valid
  }

-- Claim a fair share, renew held leases, expire stale ones in one pass; returns
-- the set of buckets this worker owns AFTER the pass.
acquireOwnedBuckets :: (IOE :> es, Store :> es)
                    => ShardLease -> Int {- live worker estimate -} -> Eff es (Set Int)
renewOwnedBuckets   :: (IOE :> es, Store :> es) => ShardLease -> Eff es (Set Int)
relinquish          :: (IOE :> es, Store :> es) => ShardLease -> Set Int -> Eff es ()
```

The **fair share** target is `ceil(N / liveWorkers)`: a worker claims up to that many buckets,
so when `k` workers are live they collectively claim all `N` buckets and no single worker hogs
them. `liveWorkers` is estimated from the table (count of distinct non-expired
`owner_worker_id` plus one for self); a slightly stale estimate only changes how aggressively a
worker claims and self-corrects on the next pass — it never causes double ownership, because the
`FOR UPDATE SKIP LOCKED` claim is the actual exclusion mechanism.

Acceptance: a unit test (Milestone 2 in Concrete Steps) seeds `N=4` rows, has worker A claim 4,
worker B claim 0 (all owned), advances simulated time past A's TTL without A renewing, and shows
B can now claim the expired buckets — disjointness and expiry verified at the SQL layer.

### Milestone 3 — the rebalance loop (keiro-side)

Scope: the driver that turns owned buckets into running kiroku consumer-group readers. At the
end, one process with `N=4` and one worker owns all 4 buckets and drains a seeded category.

Create `/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Subscription/Shard/Worker.hs`:

```haskell
data ShardedWorkerOptions = ShardedWorkerOptions
  { shardCount    :: !Int            -- N buckets (fixed per subscription)
  , leaseTtl      :: !NominalDiffTime  -- default 30s
  , renewInterval :: !NominalDiffTime  -- default 10s (well under TTL: ~3 renews per TTL)
  , target        :: !SubscriptionTarget   -- the Category to shard
  , metrics       :: !(Maybe KeiroMetrics)
  }

-- The single testable pass: reconcile ownership once, then ensure exactly the
-- owned buckets have a running reader (start newly-owned, stop newly-lost).
reconcileShardsOnce
  :: (IOE :> es, Store :> es)
  => ShardLease -> ShardedWorkerOptions
  -> IORef (Map Int RunningReader)   -- bucket -> its live adapter/cancel handle
  -> Handler es RecordedEvent
  -> Eff es (Set Int)                 -- buckets owned after this pass

-- The loop driver: spawn the worker id, ensureShardRows, then forever
-- reconcileShardsOnce on renewInterval, renewing leases each pass.
runShardedSubscriptionGroup
  :: (IOE :> es, Store :> es)
  => KirokuStore -> SubscriptionName -> ShardedWorkerOptions
  -> Handler es RecordedEvent -> Eff es ()
```

Each pass: (a) `expire`+`claim`+`renew` via Milestone 2 to compute the owned-bucket set; (b)
for each newly owned bucket, open a `kirokuAdapter` with
`consumerGroup = Just (ConsumerGroup (fromIntegral bucket) (fromIntegral N))` on this
`subscriptionName` and `target`, wire it to the handler through a shibuya processor, and record
its cancel action; (c) for each newly lost bucket, call the recorded `shutdown`/cancel so this
process stops reading a slice it no longer owns (preventing duplicate processing during a
rebalance). Because kiroku per-member checkpoints persist, a bucket that moves to another worker
resumes at its own saved position — no gap.

The lease TTL/renew relationship is the safety margin: with `renewInterval = 10s` and
`leaseTtl = 30s`, a live worker renews ~3× per TTL, so a single missed renewal (GC pause, brief
network blip) does not lose ownership, but a *dead* worker loses every bucket within ~30s.

Acceptance: one process, `N=4`, seed a category with events on many streams, run
`runShardedSubscriptionGroup`, and observe the handler processes every event exactly once
(counts in a test sink table equal the seeded total).

### Milestone 4 — forward the upstream surface (documentation)

Scope: record in `docs/research/11-upstream-roadmap.md` the two quality-of-life upstream asks
that would simplify EP-51 but are not required to ship it. Append two new entries (numbered to
follow the existing kiroku §4.x / shibuya §6.x series — §4.11 and §6.2):

1. **kiroku-store §4.11 — dynamic-membership consumer group (Wanted, Optional).** Today a
   keiro sharded worker opens *one `kirokuAdapter` per owned bucket* (N subscriptions when it
   owns N buckets). A kiroku variant taking an *owned-bucket set* — e.g.
   `consumerGroup = Just (ConsumerGroupSet { ownedMembers :: Set Int32, size :: Int32 })` whose
   SQL predicate is `member_of(stream_id) = ANY($owned)` — would let one subscription serve all
   of a worker's buckets, halving connection/worker count. Provenance: EP-51 Milestone 3.
   Design constraint: must preserve per-member checkpoints so a bucket re-homed to another
   worker resumes at its own position; the predicate change is `= ANY(...)` over the same hash.

2. **shibuya-core §6.2 — shard-aware supervised non-adapter worker (Wanted, Optional).** EP-51's
   rebalance loop is a polling loop, not adapter-shaped, exactly like the timer/outbox workers
   (§6.1 already forwards the generalisation). A shibuya supervised entry point for a plain
   `Eff es ()` worker with restart policy + OpenTelemetry spans would let the rebalance loop and
   its per-bucket readers be observed uniformly. Provenance: EP-51 Milestone 3; ties to existing
   §6.1.

Record here (in this plan, after writing them) the exact section numbers used.

### Milestone 5 — disjoint-drain + failover acceptance (keiro-side)

Scope: the behavioural proof. At the end, an integration test demonstrates the three acceptance
facts from Purpose. This is the milestone that proves the feature *works*, not merely compiles.

The test (under `keiro/test/`, using the suite-level template-database fixture from
keiro-test-support per the project memory note on ephemeral-pg) does:

1. Seed category `orders` with, say, 1000 events spread across 200 distinct streams
   (`orders-<uuid>`), so every bucket gets a non-trivial slice.
2. Start three sharded worker "processes" (in-process: three `runShardedSubscriptionGroup`
   `Async` threads, each with its own `WorkerId`, `N = 6`), each handler appending
   `(workerId, streamKey, eventId)` to a test sink table.
3. Wait until the sink count equals 1000. Assert: per-`workerId` counts **sum to 1000**; the
   set of `eventId`s is exactly the seeded set (**no gaps, no duplicates**); each `streamKey`
   appears under **exactly one `workerId`** (disjoint ownership).
4. Kill one worker thread mid-drain (cancel its `Async`, which stops renewals; do not call
   `relinquish` so failover is via lease *expiry*, the real crash path). Seed more events on the
   killed worker's streams. Within ~`leaseTtl` a surviving worker re-claims those buckets and
   drains the new events. Assert the new events are processed (failover), still with no duplicate
   `eventId`.

Acceptance is phrased entirely as behaviour over the sink table: counts-sum-to-total, no key
twice, killed buckets re-drained.

### Milestone 6 — optional EP-50 push signalling (soft-dep)

Scope: if EP-50 (LISTEN/NOTIFY push delivery,
`docs/plans/50-listen-notify-push-delivery-for-subscriptions-and-workflow-resume.md`) has
landed, replace the pure poll wait between rebalance passes with a wait on the EP-50 channel
(`NOTIFY keiro_shard_rebalance, '<subscription_name>'` on claim/release), so a join or a
voluntary relinquish triggers an immediate rebalance instead of waiting up to `renewInterval`.
If EP-50 has not landed, the polled loop is the shipped default; record the seam (a single
`waitForRebalanceSignal :: Eff es ()` that is either `threadDelay renewInterval` or a channel
wait) so the upgrade is a one-function swap. This milestone is purely a latency improvement;
correctness (disjointness, failover) does not depend on it.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.
The project builds with `cabal`. (If the repo uses a Nix dev shell, prefix with the project's
usual `nix develop -c` wrapper; the commands below assume the toolchain is already on PATH.)

### Milestone 1

```bash
# 1. Create the migration file (content shown in Plan of Work, Milestone 1).
$EDITOR keiro-migrations/sql-migrations/2026-06-03-03-00-00-keiro-subscription-shards.sql

# 2. Bump the embedDir touch-comment so GHC re-embeds the new file.
$EDITOR keiro-migrations/src/Keiro/Migrations.hs   # add the new filename to the listed set

# 3. Rebuild the migrations package (cabal clean if the new .sql is not picked up).
cabal build keiro-migrations
```

Expected: a clean build. Then apply migrations against a scratch database and inspect the table.
The exact apply entry point is `Keiro.Migrations.runAllKeiroMigrationsNoCheck` (used by the test
support); the test suite applies it automatically, so the cleanest verification is the Milestone
2 unit test below. For a manual check, after the test DB is created:

```text
\d kiroku.keiro_subscription_shards
-- columns: subscription_name text, bucket int, shard_count int,
--          owner_worker_id uuid, lease_expires_at timestamptz,
--          heartbeat_at timestamptz, updated_at timestamptz
-- PK (subscription_name, bucket); two indexes (owner, lease).
```

### Milestone 2

```bash
$EDITOR keiro/src/Keiro/Subscription/Shard/Schema.hs   # SQL statements
$EDITOR keiro/src/Keiro/Subscription/Shard.hs          # typed wrappers + WorkerId/ShardLease
# Register both modules in keiro/keiro.cabal (exposed-modules).
$EDITOR keiro/keiro.cabal
cabal build keiro
# Add and run the lease unit test:
$EDITOR keiro/test/...ShardLeaseSpec.hs
cabal test keiro --test-options='--match "/Shard lease/"'
```

Expected transcript (shape):

```text
Shard lease
  ensureShardRows populates N rows once (idempotent on re-run)   [OK]
  claimShards: worker A claims all N when free                   [OK]
  claimShards: worker B claims 0 while A holds valid leases       [OK]
  claimShards: B claims A's buckets after A's lease expires       [OK]
  renewLease: returns only still-held buckets                     [OK]
  releaseShards: relinquished buckets are immediately claimable   [OK]
```

### Milestone 3

```bash
$EDITOR keiro/src/Keiro/Subscription/Shard/Worker.hs
$EDITOR keiro/keiro.cabal
cabal build keiro
cabal test keiro --test-options='--match "/Sharded subscription single worker/"'
```

Expected: the single-worker drain test reports the sink count equals the seeded total.

### Milestone 4

```bash
$EDITOR docs/research/11-upstream-roadmap.md   # append §4.11 and §6.2 entries
```

No build. Verify the two entries follow the existing per-entry shape (What is missing / What
keiro needs / Why / Priority / Design constraint / Suggested sequencing / Provenance).

### Milestone 5

```bash
$EDITOR keiro/test/...ShardFailoverSpec.hs
cabal test keiro --test-options='--match "/Sharded subscription drain and failover/"'
```

Expected transcript (shape):

```text
Sharded subscription drain and failover
  three workers drain a category disjointly (counts sum to total) [OK]
  no stream key is processed by two workers                       [OK]
  no event id is processed twice and none is missing              [OK]
  killing a worker re-homes its buckets after lease expiry         [OK]
```


## Validation and Acceptance

The feature is accepted when the Milestone 5 test passes, demonstrating behaviour a human can
read off the sink table:

- **Disjoint drain (throughput).** With `N=6` buckets and three workers draining a category of
  1000 events across 200 streams, summing the per-`workerId` processed counts yields exactly
  1000, and grouping the sink rows by `streamKey` shows each key under exactly one `workerId`.
  This proves the keyspace is partitioned with no duplicate processing and no gaps.
- **Failover.** After one worker is killed (its renewals stop), new events on its former streams
  are processed by a surviving worker within roughly `leaseTtl` seconds, with no `eventId`
  processed twice. This proves a dead owner's buckets are re-claimed via lease expiry.
- **No external coordinator.** The only infrastructure the test starts is Postgres; there is no
  etcd/ZooKeeper process. Coordination is entirely in `keiro_subscription_shards`.

These are checked beyond compilation: the test fails before the feature exists (no rebalance ⇒
either nothing drains, or, if all three workers read all buckets unpartitioned, the same
`eventId` appears under multiple `workerId`s ⇒ the "no duplicates" assertion fails) and passes
after.


## Idempotence and Recovery

- **Migration (Milestone 1)** uses `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT
  EXISTS`; re-running it is a no-op. codd tracks applied versions, so a re-apply is safe.
- **`ensureShardRows`** uses `ON CONFLICT DO NOTHING`; calling it on every worker startup is
  safe and converges the table to exactly `N` rows.
- **Claiming** is safe under concurrency by construction: `FOR UPDATE SKIP LOCKED` guarantees
  two workers cannot both win the same row, so a bad `liveWorkers` estimate never causes double
  ownership — only a different claim aggressiveness that self-corrects next pass.
- **Crash mid-pass.** A worker that dies between claim and the next renew simply stops renewing;
  its leases expire and the buckets become claimable. A worker that dies after claiming but
  before opening the reader leaves an owned-but-unread bucket for up to one TTL — bounded, and
  re-homed on expiry. No event is lost because kiroku per-member checkpoints persist; a re-homed
  bucket resumes at its saved position.
- **Duplicate processing during rebalance.** When a bucket moves owners, the losing worker stops
  its reader (Milestone 3 step c) before/around the time the winner starts; a brief overlap can
  redeliver a handful of events. This is the same at-least-once contract keiro already documents
  for async projections — handlers must be idempotent (write keyed on `eventId`), exactly as the
  existing process-manager/projection guidance requires. The acceptance test's "no `eventId`
  twice" assertion is satisfied by an idempotent sink (`INSERT ... ON CONFLICT (event_id) DO
  NOTHING`), matching how a real handler behaves.
- **Retry.** Every step is re-runnable: rebuild and re-test freely; the lease table self-heals
  from any partial state via expiry + `ensureShardRows`.


## Interfaces and Dependencies

### New database table

`keiro_subscription_shards` in the `kiroku` schema (Milestone 1), keyed
`(subscription_name, bucket)`, carrying `shard_count`, `owner_worker_id`, `lease_expires_at`,
`heartbeat_at`, `updated_at`. Migration
`keiro-migrations/sql-migrations/2026-06-03-03-00-00-keiro-subscription-shards.sql`.

### New keiro modules and signatures

`Keiro.Subscription.Shard.Schema` (full path
`/Users/shinzui/Keikaku/bokuno/keiro/keiro/src/Keiro/Subscription/Shard/Schema.hs`):

```haskell
ensureShardRows   :: SubscriptionName -> Int -> Tx.Transaction ()
claimShardsTx     :: SubscriptionName -> WorkerId -> Int -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]
renewLeaseTx      :: SubscriptionName -> WorkerId -> UTCTime -> NominalDiffTime -> Tx.Transaction [Int]
releaseShardsTx   :: SubscriptionName -> WorkerId -> [Int] -> Tx.Transaction ()
listShardOwnership:: SubscriptionName -> Tx.Transaction [(Int, Maybe WorkerId, Maybe UTCTime)]
```

`Keiro.Subscription.Shard` (`.../Keiro/Subscription/Shard.hs`):

```haskell
newtype WorkerId = WorkerId UUID
freshWorkerId       :: IOE :> es => Eff es WorkerId
data ShardLease     = ShardLease { subscriptionName :: SubscriptionName, workerId :: WorkerId, shardCount :: Int, leaseTtl :: NominalDiffTime }
acquireOwnedBuckets :: (IOE :> es, Store :> es) => ShardLease -> Int -> Eff es (Set Int)
renewOwnedBuckets   :: (IOE :> es, Store :> es) => ShardLease -> Eff es (Set Int)
relinquish          :: (IOE :> es, Store :> es) => ShardLease -> Set Int -> Eff es ()
```

`Keiro.Subscription.Shard.Worker` (`.../Keiro/Subscription/Shard/Worker.hs`):

```haskell
data ShardedWorkerOptions = ShardedWorkerOptions { shardCount :: Int, leaseTtl :: NominalDiffTime, renewInterval :: NominalDiffTime, target :: SubscriptionTarget, metrics :: Maybe KeiroMetrics }
reconcileShardsOnce        :: (IOE :> es, Store :> es) => ShardLease -> ShardedWorkerOptions -> IORef (Map Int RunningReader) -> Handler es RecordedEvent -> Eff es (Set Int)
runShardedSubscriptionGroup:: (IOE :> es, Store :> es) => KirokuStore -> SubscriptionName -> ShardedWorkerOptions -> Handler es RecordedEvent -> Eff es ()
```

### Libraries and modules consumed (why)

- `Kiroku.Store.Subscription.Types.ConsumerGroup (member, size)` and
  `Shibuya.Adapter.Kiroku.kirokuAdapter` (`consumerGroup` field) — the bucket *mechanism*. EP-51
  owns assignment; kiroku owns partitioning and per-member checkpoints. Full paths in Context.
- `Kiroku.Store.Transaction.runTransaction` — runs the lease SQL in a short transaction against
  kiroku's pool, exactly as `Keiro.Outbox`/`Keiro.Timer` do.
- `Kiroku.Store.Effect.Store` — the effect every keiro DB path threads.
- `Keiro.Telemetry.KeiroMetrics` — the optional metrics handle, threaded as `Maybe` for the
  no-op-under-`Nothing` idiom the timer/outbox/resume workers use.

### Upstream asks (forwarded, not depended on)

Forwarded to `docs/research/11-upstream-roadmap.md` (Milestone 4): kiroku §4.11
(dynamic-membership / owned-bucket-set consumer group) and shibuya §6.2 (shard-aware supervised
non-adapter worker entry point). Both are **Optional/Wanted**: EP-51 ships fully without them
using one `kirokuAdapter` per owned bucket and a keiro-hosted poll loop.

### Dependencies on other plans

- **Soft-depends on EP-50** (`docs/plans/50-listen-notify-push-delivery-for-subscriptions-and-workflow-resume.md`).
  If EP-50 lands first, Milestone 6 signals rebalance over its LISTEN/NOTIFY channel for prompt
  failover/join; if not, EP-51 ships with a polled rebalance loop and the channel swap is a
  one-function change (`waitForRebalanceSignal`). Correctness does not depend on EP-50.
- No hard dependency on any other plan; the kiroku consumer-group substrate it builds on is
  already shipped.


## Git trailers

Every commit while working on this plan must carry these trailers (separated from the message
body by a blank line):

```text
MasterPlan: docs/masterplans/6-v2-durable-execution-phase-2-rotation-versioning-push-delivery-and-sharding.md
ExecPlan: docs/plans/51-consumer-group-sharding-for-category-subscriptions.md
Intention: intention_01kt7npy22e5tb3ybycsgeqdnm
```
