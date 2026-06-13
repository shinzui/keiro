---
id: 10
slug: keiro-pgmq-queue-feature-expansion-fifo-ordering-headers-provisioning-observability
title: "keiro-pgmq queue-feature expansion: FIFO ordering, headers, provisioning, observability"
kind: master-plan
created_at: 2026-06-13T14:29:18Z
intention: "intention_01kv0jvq2qe70reyz4f6dpfxnk"
---

# keiro-pgmq queue-feature expansion: FIFO ordering, headers, provisioning, observability

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

`keiro-pgmq` (in this repository, directory `keiro-pgmq/`) is the typed background-job
queue: an application declares a `Job p` value (a queue, a payload codec, a retry/DLQ
policy) and writes a plain handler `p -> Eff es JobOutcome`, and the package runs it
against PGMQ (a PostgreSQL-native message queue) through shibuya (a Broadway-style worker
framework). As of `docs/plans/74-expose-keiro-pgmq-tuning-surface-and-make-job-workers-resilient.md`
(complete — its 8 milestones are all landed; commits `880bf13`…`2066bfd`), the package has
a solid *resilience and tuning* surface: `JobTuning` (visibility timeout, batch size,
polling cadence including database long-poll), `JobContext` (lease extension, attempt
number), validated smart constructors (`mkJobTuning`, `mkRetryPolicy`), structured decode
errors with rolling-deploy-safe version-ahead retry (`JobDecodeError`), a real one-shot
drain (`runJobOnceWithContext`), collision-free queue naming, and a dead-letter inspection
and redrive module (`Keiro.PGMQ.Dlq` — `readDlq`/`redriveDlq`/`purgeDlq`).

But the *queue-feature* surface is still thin. PGMQ itself — and the `shibuya-pgmq-adapter`
keiro-pgmq already builds on — supports a great deal that keiro-pgmq does not yet expose.
The two most consequential gaps, and the ones this initiative closes, are **ordered
delivery** and **message metadata**. PGMQ's standard `read` is FIFO only in *selection*
order (`msg_id` ascending), but under concurrent workers (`FOR UPDATE SKIP LOCKED`),
retries, and visibility-timeout expiry it gives **no FIFO delivery guarantee**. Strict
per-key ordering requires PGMQ *message groups*: messages carrying the same value under the
reserved `x-pgmq-group` JSONB header are delivered in strict order while different groups
proceed in parallel, read through `read_grouped` / `read_grouped_rr`. The shibuya adapter
*already* implements both grouped read strategies behind its `PgmqAdapterConfig.fifoConfig`
field — keiro-pgmq simply never sets it, and its producers never write the grouping header.
Likewise, keiro-pgmq's producers (`enqueue`/`enqueueWithDelay`) send with **no headers at
all**, so there is no way to attach a FIFO group key, propagate a W3C `traceparent` for
distributed tracing across the enqueue→dequeue boundary, or carry any application metadata —
even though the package's own DLQ path already uses `sendMessageWithHeaders` to *preserve*
headers it never lets callers *set*.

After this initiative, a keiro application can:

- **Order work by key.** Declare a `Job` whose enqueues carry a group key and whose
  consumers read with a FIFO strategy (throughput-optimized or fair round-robin), so all
  messages for one key (one aggregate, one tenant, one user) are processed strictly in
  order while distinct keys run concurrently. This is the headline capability and the
  user's primary ask.
- **Attach and read message headers,** including propagating an OpenTelemetry trace context
  from producer to handler, and enqueue **batches** in one round-trip.
- **Provision the right kind of queue declaratively** — standard, unlogged (faster, crash-
  truncated, for transient work), or partitioned (pg_partman-backed, for high-throughput
  retention by time or message count) — and create the GIN FIFO index that grouped reads
  need.
- **Observe queues** through a first-class typed metrics surface (main-queue and DLQ depth,
  oldest/newest message age, cumulative throughput) and **archive** messages for audit
  retention rather than only deleting or dead-lettering them.

Every new capability is proven by a behavioral test in the `keiro-pgmq-test` suite (which
`#74` already moved onto `keiro-test-support`'s isolated per-example databases), runnable
from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` with:

```bash
cabal test keiro-pgmq-test
```

In scope: producer headers + trace propagation + batch enqueue (EP-1); declarative queue
provisioning for unlogged/partitioned queues and FIFO indexes (EP-2); FIFO ordered delivery
via message groups on both the worker and one-shot drain paths (EP-3); a queue metrics and
archive/retention API (EP-4). All four extend the existing `keiro-pgmq` package in place and
build on the `#74` surface; none requires a change to any other repository.

Explicitly excluded, captured as roadmap docs so the design is not lost:

- **Conditional reads** (server-side message filtering on the worker path). PGMQ's `read`
  takes a `conditional` JSONB filter, but `shibuya-pgmq-adapter` hard-codes it to `Nothing`
  (`Internal.hs`, `mkReadMessage`/`mkReadWithPoll`), so enabling it on the *worker* path
  needs a patch to that separate repository plus a version bump. No keiro consumer needs it
  today. Recorded at `docs/roadmap/pgmq-conditional-reads-worker-path.md`.
- **PGMQ topic routing / fan-out as an integration-event transport** (case B). This is a
  delivery-transport concern for domain integration events (a Kafka alternative), already
  captured at `docs/roadmap/pgmq-as-transport-for-integration-events.md`, and it must build
  on `Keiro.PGMQ.Runtime`, **not** on the `Job` layer this initiative extends. Out of scope
  here.


## Decomposition Strategy

The initiative is decomposed by **functional concern** into four child plans, grouped into
two implementation waves. The decisive split is between the three *foundational* feature
surfaces that are mutually independent (producer metadata, queue provisioning, observability)
and the one *composite* feature that consumes two of them (FIFO ordered delivery needs both
header-keyed enqueue and a FIFO index).

The producer surface (EP-1) is foundational: message headers are the substrate for two
distinct features — distributed-trace propagation and the FIFO group key — plus batch
enqueue is a natural producer-side companion. Isolating "everything that changes how work is
*put on* the queue" into one plan means the header model (how a `Job` enqueue carries a
`MessageHeaders` value, how a handler reads it back through `JobContext`) is designed once,
coherently, and the FIFO plan can then express a group key as "a particular header" rather
than reinventing metadata plumbing.

Queue provisioning (EP-2) is foundational and independent: it changes how queues are
*created* (standard vs unlogged vs partitioned) and adds FIFO-index creation. It is separated
from EP-1 because provisioning is a lifecycle/admin concern with no overlap with the
send path, and it is a hard prerequisite for EP-3 only for the narrow artifact of the FIFO
GIN index (grouped reads are correct without it but do a sequential scan; the index is what
makes ordered delivery perform).

Observability and archival (EP-4) is foundational and fully independent: a read-only metrics
surface plus an archive operation touch neither the send path nor the consume path's
ordering. It is its own plan because it is the one purely *operational* surface (depth
alerting, audit retention) and pairs naturally with — but does not depend on — `#74`'s
`Keiro.PGMQ.Dlq` retention story.

FIFO ordered delivery (EP-3) is the composite headline plan and the only one with hard
dependencies. It needs EP-1's header-keyed enqueue (the `x-pgmq-group` group key is a
header) and EP-2's FIFO index (so grouped reads perform). It then adds the ordering
*semantics*: a typed group-key enqueue, a FIFO read strategy that maps to the shibuya
adapter's existing `fifoConfig` on the worker path and to grouped reads on the drain path,
and the documentation of exactly which ordering guarantee holds. Putting ordering last lets
it build on settled foundations rather than co-evolving three designs at once.

Aim and balance: four plans sit inside the two-to-seven guidance, so two waves (rather than
formal phases) suffice. EP-1, EP-2, and EP-4 can be implemented in parallel by different
sessions immediately; EP-3 follows once EP-1 and EP-2 land.

Alternatives considered. **Folding headers into the FIFO plan** was rejected: trace
propagation and batch enqueue are valuable on their own and have consumers (the keiro-dsl
dispatch nodes' external producer already hand-rolls `sendMessageWithHeaders` for
`traceparent`) independent of ordering; coupling them would deny those uses until FIFO lands
and would bloat one plan. **Merging provisioning into observability** (an "admin" plan) was
rejected because creation and inspection are different lifecycle phases with different risk
profiles (provisioning is write/DDL and a hard dependency of FIFO; metrics are read-only and
depend on nothing), and merging would serialize FIFO behind unrelated metrics work.
**Putting FIFO ordering knobs on a *new* config record** rather than extending `#74`'s
`JobTuning` was rejected (see Integration Points): `JobTuning` is already the consumption-
site home for "how a consumer reads the queue," and a FIFO read strategy is exactly that —
adding a competing record would fragment the tuning surface. **A separate library package**
was rejected: these are first-class `Job`-layer features, not a new transport, so they belong
in `keiro-pgmq` alongside the surface they extend.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Add message headers, trace propagation, and batch enqueue to keiro-pgmq producers | docs/plans/75-add-message-headers-trace-propagation-and-batch-enqueue-to-keiro-pgmq-producers.md | None | None | Complete |
| 2 | Add partitioned and unlogged queue provisioning with FIFO indexes to keiro-pgmq | docs/plans/76-add-partitioned-and-unlogged-queue-provisioning-with-fifo-indexes-to-keiro-pgmq.md | None | None | Complete |
| 3 | Add FIFO ordered delivery via message groups to keiro-pgmq | docs/plans/77-add-fifo-ordered-delivery-via-message-groups-to-keiro-pgmq.md | EP-1, EP-2 | EP-4 | Complete |
| 4 | Add queue metrics and archive/retention API to keiro-pgmq | docs/plans/78-add-queue-metrics-and-archive-retention-api-to-keiro-pgmq.md | None | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled, Deferred.
Hard Deps and Soft Deps reference other rows by their `#` prefix (e.g., EP-1). All four plans
build on the now-complete `docs/plans/74-…` surface; that is a satisfied baseline, not a
tracked dependency. Conditional reads (worker path) and PGMQ-as-integration-transport (case
B) are deferred to roadmap docs and are not rows here.


## Dependency Graph

EP-1 (producers), EP-2 (provisioning), and EP-4 (observability) have **no dependencies on
each other** and may all proceed in parallel the moment the initiative starts. Each touches a
disjoint slice of the package: EP-1 the send path (`enqueue` family in
`keiro-pgmq/src/Keiro/PGMQ/Job.hs` and the handler-side `JobContext`), EP-2 the queue-
creation path (`ensureJobQueue` and `Keiro.PGMQ.Runtime`/a new provisioning surface), EP-4 a
new read-only metrics module plus an archive operation. They share no function they both
modify.

EP-3 (FIFO ordered delivery) has **hard** dependencies on EP-1 and EP-2:

- On **EP-1** because a FIFO group is expressed as the reserved `x-pgmq-group` JSONB header
  on the enqueued message. EP-3's group-keyed producer (`enqueueOrdered`/`enqueueToGroup`)
  is a thin specialization of EP-1's header-carrying enqueue; without EP-1 there is no way to
  set that header, so EP-3's producer code would not compile or would re-derive header
  plumbing EP-1 owns.
- On **EP-2** because grouped reads (`read_grouped`, `read_grouped_rr`) match group messages
  through a GIN index on the `headers` column; without EP-2's `createFifoIndex` wiring in the
  queue-provisioning path, grouped reads still return correct results but fall back to a
  sequential scan, which is not an acceptable production default. EP-2 owns the index-creation
  artifact EP-3's `ensureJobQueue` path must invoke.

EP-3 has a **soft** dependency on EP-4: EP-4's metrics surface is the natural way to observe
a FIFO queue's per-group backlog and is referenced from EP-3's operational documentation, but
EP-3 does not require EP-4's code to compile or pass tests. If EP-4 has not landed, EP-3
documents the raw `Pgmq.Effectful.queueMetrics` call instead and adds a reconcile note.

So the critical path is EP-1 ∥ EP-2 → EP-3, with EP-4 floating alongside. The earliest the
initiative completes is `max(EP-1, EP-2) + EP-3` wall-clock, with EP-4 absorbed into that
window.


## Integration Points

**1. `JobTuning` as the consumption-site config home (EP-3 extends what `#74` defined; also
read by the worker and drain paths).** `#74` introduced `JobTuning` in
`keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

```haskell
data JobPolling = PollEvery !NominalDiffTime | LongPoll !Int32 !Int32
  deriving stock (Eq, Show)

data JobTuning = JobTuning
  { visibilityTimeout :: !Int32
  , batchSize         :: !Int32
  , polling           :: !JobPolling
  }
  deriving stock (Eq, Show)

mkJobTuning :: Int32 -> Int32 -> JobPolling -> Either JobTuningConfigError JobTuning
defaultJobTuning :: JobTuning  -- 30 s vt, batch 1, PollEvery 1
```

`JobTuning` is consumed at `jobProcessorWithContext :: JobTuning -> Job p -> (JobContext es
-> p -> Eff es JobOutcome) -> Eff es (ProcessorId, QueueProcessor es)` and
`runJobOnceWithContext :: JobTuning -> Int -> Job p -> (JobContext es -> p -> Eff es
JobOutcome) -> Eff es Int`, and mapped to the shibuya adapter inside `adapterConfigFor ::
JobTuning -> Job p -> PgmqAdapterConfig`. **EP-3 owns the decision of how a FIFO read
strategy attaches here.** The decided approach (see Decision Log) is to add an *ordering*
field to `JobTuning` (e.g. `ordering :: JobOrdering` where `data JobOrdering = Unordered |
FifoThroughput | FifoRoundRobin`) with a smart-constructor arm and a `defaultJobTuning`
default of `Unordered` so existing call sites are unchanged in behavior. EP-3 maps that field
to `PgmqAdapterConfig.fifoConfig` in `adapterConfigFor` for the worker path, and to grouped-
read calls in the `runJobOnceWithContext` drain. Because `JobTuning`'s constructor is strict,
EP-3 must update every in-repo `JobTuning`/`mkJobTuning` construction site when it adds the
field; the affected sites are the `keiro-pgmq-test` suite and any keiro-dsl fixture that
builds a `JobTuning` (grep before editing). No other plan modifies `JobTuning`.

**2. The header-carrying enqueue (EP-1 defines; EP-3 specializes).** EP-1 defines how an
enqueue carries a `Pgmq.Effectful.MessageHeaders` (a `newtype` over an aeson `Value`). The
contract EP-3 relies on is a public producer that accepts headers, e.g.:

```haskell
-- Defined by EP-1 in Keiro.PGMQ.Job (exact name/shape is EP-1's to finalize;
-- EP-3 depends only on "an enqueue that sets headers"):
enqueueWithHeaders :: (Pgmq :> es, IOE :> es) => Job p -> MessageHeaders -> p -> Eff es MessageId
```

EP-3 builds its group-keyed producer on top by setting the reserved `x-pgmq-group` key:
`enqueueToGroup job groupKey p = enqueueWithHeaders job (groupHeader groupKey) p` where
`groupHeader k = MessageHeaders (object ["x-pgmq-group" .= k])`. The group-key header name is
**`x-pgmq-group`** verbatim — this is the literal PGMQ and shibuya-adapter contract
(`shibuya-pgmq-adapter` `Convert.hs` extracts the group from this exact key). If EP-1 chooses
a different header API shape than the sketch above, it must update this section and EP-3's
"Interfaces and Dependencies" before EP-3 begins. EP-1 must also ensure that whatever header
API it ships does not *reserve* or strip `x-pgmq-group`, so EP-3 can set it.

**3. The FIFO GIN index creation (EP-2 defines; EP-3 invokes).** EP-2 adds the ability to
create PGMQ's FIFO index (the GIN index on the `headers` column that `read_grouped` matches
against), either via `pgmq-config`'s `withFifoIndex`/`ensureQueuesEff` reconciler or via a
direct `createFifoIndex :: QueueName -> Pgmq m ()` call (note: `createFifoIndex` is exported
from `Pgmq.Effectful.Effect`, **not** from the `Pgmq.Effectful` umbrella, so the import is
`import "pgmq-effectful" Pgmq.Effectful.Effect (createFifoIndex)` — EP-2 documents the exact
import it standardizes on). EP-3's queue-setup path (an enhanced `ensureJobQueue` or a FIFO-
aware variant) calls EP-2's index-creation function when the job is ordered. EP-2 owns the
function; EP-3 owns the decision to call it for ordered jobs. If EP-2 has not yet exposed a
named index helper when EP-3 starts, EP-3 may call `createFifoIndex` directly and leave a
reconcile note to route through EP-2's helper once it lands.

**4. The `Job`/`QueueRef` value (shared read-only context by all four).** All four plans read
`Job p` (`jobName`, `jobQueue :: QueueRef`, `jobCodec :: JobCodec p`, `jobPolicy ::
RetryPolicy`) and `QueueRef` (`logicalName`, `physicalName :: QueueName`, `dlqName ::
QueueName`) from `keiro-pgmq/src/Keiro/PGMQ/Job.hs` and `…/Runtime.hs`. **No plan changes
`Job`'s or `QueueRef`'s fields.** EP-1 adds producer functions that take a `Job`; EP-2 adds a
provisioning surface that may take a `Job` or a `QueueRef`; EP-4 keys metrics/archive on a
`Job` or `QueueRef`. Keeping these record shapes frozen is what lets the four plans stay
independent — any plan that finds it must change `Job`'s fields must raise it here first,
because a strict-field change to `Job` is a cross-cutting breaking change touching every other
plan and the keiro-dsl fixtures.

**5. `Keiro.PGMQ` umbrella re-exports (every plan that adds public surface).** New public
types/functions must be re-exported from the umbrella module `keiro-pgmq/src/Keiro/PGMQ.hs`
so consumers `import Keiro.PGMQ` and get everything. EP-4's new module
(`Keiro.PGMQ.Metrics` or similar) must be added to both `exposed-modules` in
`keiro-pgmq/keiro-pgmq.cabal` and the umbrella's re-export list, exactly as `#74` did for
`Keiro.PGMQ.Dlq`. EP-1 and EP-3 extend `Keiro.PGMQ.Job`'s export list; the umbrella already
re-exports the whole module, so no umbrella edit is needed for those.


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1: Header-carrying enqueue (`enqueueWithHeaders`) + reserved-key safety, exported and tested. (2026-06-13)
- [x] EP-1: Batch enqueue (`enqueueBatch`, with-headers/with-delay variants) over `batchSendMessage`. (2026-06-13)
- [x] EP-1: Handler-visible headers on `JobContext` (worker + drain paths), incl. W3C `traceparent` propagation helper. (2026-06-13)
- [x] EP-2: `QueueType` (standard/unlogged/partitioned) provisioning surface for `ensureJobQueue`. (2026-06-13)
- [x] EP-2: FIFO index creation wired into provisioning (via `pgmq-config` or direct `createFifoIndex`). (2026-06-13)
- [x] EP-2: Tests — unlogged/partitioned queue creation and FIFO-index idempotence against ephemeral PG. (2026-06-13)
- [x] EP-3: `JobOrdering` on `JobTuning` mapped to the adapter `fifoConfig` (worker path). (2026-06-13)
- [x] EP-3: Grouped reads in the `runJobOnceWithContext` drain (one-shot ordered path). (2026-06-13)
- [x] EP-3: Group-keyed producer (`enqueueToGroup`) + ordered FIFO index in queue setup. (2026-06-13)
- [x] EP-3: End-to-end ordering test — same group processed in order, distinct groups concurrent. (2026-06-13)
- [ ] EP-4: Typed metrics surface (`queueDepth`/`jobMetrics` over `queueMetrics`/`allQueueMetrics`) for main + DLQ.
- [ ] EP-4: Archive operation + archive-based retention helper; tests for metrics and archive.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-06-13 (research) — **The shibuya adapter already supports FIFO grouped reads; keiro-
  pgmq just never opted in.** `shibuya-pgmq-adapter`'s `PgmqAdapterConfig` carries
  `fifoConfig :: Maybe FifoConfig` with `FifoReadStrategy = ThroughputOptimized | RoundRobin`,
  and its read dispatch (`Internal.hs`) selects `read_grouped` / `read_grouped_rr` (and their
  long-poll variants) when `fifoConfig` is set, keying the group on the `x-pgmq-group` header
  (`Convert.hs`). keiro-pgmq's `adapterConfigFor` never sets `fifoConfig`. This makes EP-3's
  *worker-path* ordering largely a config-plumbing exercise rather than new read machinery —
  the new code is in the *drain* path (`runJobOnceWithContext`), which reads directly via
  `Pgmq.readMessage` and must call grouped reads explicitly.
- 2026-06-13 (research) — **The DLQ path already sets headers; producers do not.** `#74`'s
  drain (`keiro-pgmq/src/Keiro/PGMQ/Job.hs`, `sendDlq`) calls `Pgmq.sendMessageWithHeaders`
  to *preserve* a message's headers onto the DLQ, but `enqueue`/`enqueueWithDelay` call
  `Pgmq.sendMessage` with no headers. So the wire-level header support EP-1 needs already
  exists in `pgmq-effectful` and is already a build-dep; EP-1 is exposing it on the producer
  side, not adding it.
- 2026-06-13 (research) — **Grouped reads and FIFO-index creation are not in the
  `Pgmq.Effectful` umbrella.** `createFifoIndex`, `createFifoIndexesAll`, `readGrouped`,
  `readGroupedRoundRobin`, and their poll variants are exported from `Pgmq.Effectful.Effect`
  but omitted from the `Pgmq.Effectful` umbrella re-export. EP-2 (index) and EP-3 (drain-path
  grouped reads) must import from `Pgmq.Effectful.Effect` directly. Recorded so neither plan
  loses time to a missing-symbol error against the umbrella.
- 2026-06-13 (EP-1 complete) — **EP-1 shipped exactly the Integration Point 2 contract EP-3
  depends on.** `enqueueWithHeaders :: (Pgmq :> es, IOE :> es) => Job p -> MessageHeaders -> p
  -> Eff es MessageId` is live in `Keiro.PGMQ.Job` with the agreed argument order, and the
  reserved `x-pgmq-group` key passes through verbatim (regression-guarded by the example
  `"enqueueWithHeaders leaves the x-pgmq-group key untouched"`). EP-3 can build
  `enqueueToGroup` on it without any change to Integration Point 2. `MessageHeaders (..)` is
  now re-exported from `Keiro.PGMQ.Job` (and the umbrella). The batch-with-headers producer
  takes `[(MessageHeaders, p)]` pairs, not parallel lists.
- 2026-06-13 (EP-3 complete) — **The `ReadGrouped` request record forced a new `pgmq-hasql`
  library dependency, contradicting EP-3's "no new dependency" claim.** EP-3's grouped-read
  drain needs the `ReadGrouped` *record* type, but `Pgmq.Effectful.Effect` exports a name
  `ReadGrouped` that is the `Pgmq` GADT data constructor (not the record), so `ReadGrouped (..)`
  fails to compile (GHC-35373), and the `Pgmq.Effectful` umbrella does not re-export the record
  at all. The record type lives only in `Pgmq.Hasql.Statements.Types` (package `pgmq-hasql`).
  Resolution: import the functions from `Pgmq.Effectful.Effect` and the record from
  `Pgmq.Hasql.Statements.Types`, adding `pgmq-hasql >=0.3 && <0.4` to `keiro-pgmq`'s library
  build-deps (additive; it was already a transitive dep via `pgmq-effectful`). **Relevant to a
  future EP-4** if it ever needs grouped-read or other `Pgmq.Hasql.Statements.Types`-only
  records: the umbrella is not always sufficient; check whether the record type (vs the effect
  op) is re-exported before assuming `pgmq-effectful` alone suffices.
- 2026-06-13 (EP-3 complete) — **EP-3 consumed EP-1's `enqueueWithHeaders` and EP-2's
  `ensureFifoIndex` exactly as the Integration Points specified; no reconcile note was needed.**
  `enqueueToGroup`/`enqueueToGroupWithDelay` are thin wrappers over EP-1's header producers
  writing the literal `x-pgmq-group`, and `ensureOrderedJobQueue = ensureJobQueue >>
  ensureFifoIndex` composes EP-2's helpers. The strict `ordering` field added to `JobTuning`
  (Integration Point 1) touched no construction site outside `Job.hs` — no test or keiro-dsl
  fixture builds a `JobTuning` by record literal — so the one well-justified breaking change was
  fully absorbed. `Job`/`QueueRef` stayed frozen (Integration Point 4). EP-4 remains the only
  unstarted plan; EP-3's soft dependency on it is satisfied by the raw `Pgmq.queueMetrics` call.
- 2026-06-13 (EP-2 complete) — **EP-2 shipped the Integration Point 3 artifact EP-3 needs, so
  EP-3's reconcile-note fallback is unnecessary.** `ensureFifoIndex :: (Pgmq :> es) => Job p ->
  Eff es ()` is live in `Keiro.PGMQ.Job` (and through the umbrella), routed through
  `pgmq-config`'s `ensureQueuesEff` — EP-3 calls `ensureFifoIndex job` (or provisions with
  `withFifoIndexProvision`) for ordered jobs and never imports the raw `createFifoIndex` op.
  EP-2 also added `ensureJobQueueWith :: QueueProvision -> Job p -> Eff es ()` and the pure
  `queueProvisionConfigs`; the provisioning choice is a *parameter*, so `Job`/`QueueRef`
  remain frozen (Integration Point 4 intact). `pgmq-config-0.3.0.0` is now a `keiro-pgmq`
  library + test build-dep and resolved with no `cabal.project` change.
- 2026-06-13 (EP-2 complete) — **The genuine W3C `traceparent` round-trip works in tests; no
  fallback was needed**, but it cost three test-only build-deps on `keiro-pgmq-test`
  (`hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, `hs-opentelemetry-sdk`). The
  *library* still needs no new dependency. Pattern mirrors `pgmq-effectful`'s
  `TracedInterpreterSpec` (real provider + W3C propagator + `defaultIdGenerator` + a parent
  span attached thread-locally). EP-3, whose ordering tests do not touch tracing, does not
  inherit these deps unless it chooses to.


## Decision Log

- Decision: Create a new MasterPlan (#10) rather than adding these as child plans under the
  existing production-readiness MasterPlan #9.
  Rationale: MasterPlan #9 is a *hardening* initiative (crash-safety, correctness, resilience
  of existing behavior); this is a *feature-expansion* initiative (new queue capabilities).
  They share the `keiro-pgmq` package but have different goals, success criteria, and
  reviewers. #9's `#74` is the foundation this initiative builds on, referenced by path, but
  the work is new capability, not hardening. The user confirmed this framing when scoping.
  Date: 2026-06-13

- Decision: Sequence this initiative on top of the now-complete `#74` surface, folding the
  FIFO read strategy into `#74`'s `JobTuning` rather than introducing a competing consumption-
  config record.
  Rationale: `JobTuning` is already "how a consumer reads the queue," and a FIFO read strategy
  is precisely a read concern. A parallel record would split the tuning surface and force
  consumers to thread two configs. The cost is that adding a strict `ordering` field to
  `JobTuning` touches every construction site (test suite, any keiro-dsl `JobTuning` fixture);
  EP-3 absorbs that mechanical fix, mirroring the `#74` convention of one well-justified
  breaking change owned by the plan that needs it. Captured as Integration Point 1.
  Date: 2026-06-13

- Decision: Decompose into four plans in two waves — producers (EP-1), provisioning (EP-2),
  observability (EP-4) in parallel, then FIFO ordering (EP-3) depending on EP-1 + EP-2.
  Rationale: Functional-concern decomposition with minimal cross-coupling; the three
  foundational surfaces touch disjoint code paths and are independently verifiable, while the
  one composite feature (ordering) consumes the header key (EP-1) and the FIFO index (EP-2).
  Putting ordering last lets it build on settled foundations. See Decomposition Strategy for
  rejected alternatives.
  Date: 2026-06-13

- Decision: Defer conditional reads (worker path) to a roadmap doc rather than building them
  in this initiative.
  Rationale: Enabling server-side conditional `read` filtering on the *worker* path requires
  patching `shibuya-pgmq-adapter` (a separate repository — it hard-codes the filter to
  `Nothing`) plus a cross-repo version bump, and no keiro consumer needs it today. The design
  and the required cross-repo change are captured at
  `docs/roadmap/pgmq-conditional-reads-worker-path.md`. The user chose "defer to roadmap"
  when scoping.
  Date: 2026-06-13


## Outcomes & Retrospective

(To be filled during and after implementation.)
