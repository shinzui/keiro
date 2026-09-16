---
id: 116
slug: enforce-fifo-group-ordering-under-failure-and-batched-consumption
title: "Enforce FIFO group ordering under failure and batched consumption"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
intention: "intention_01m2b1p3vhe179jtr5qz6ghqks"
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
provenance:
  revisions:
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T13:26:48Z
      mode: "update"
      note: "Validated that MasterPlan 17 was not migrated to the pgmq project; refreshed pgmq 0.6/migration-0007 premises and recorded read_grouped_head"
    - model: "claude-opus-5[1m]"
      harness: "claude-code"
      at: 2026-09-12T14:36:53Z
      mode: "update"
      note: "Relocated the upstream SQL/doc scope to pgmq-hs MasterPlan 5; rewrote upstream milestones as consumption"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-12T17:28:45Z
      mode: "update"
      note: "Audited local downstream changes and aligned handoffs with client-only ordering, optional additive indexes, and no SQL overrides."
    - model: "claude-opus-5"
      harness: "claude-code"
      at: 2026-09-12T19:57:40Z
      mode: "update"
      note: "Decoupled 116/118 bounds: client-ordering pgmq-hasql bound vs version-free supplemental index"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T12:25:11Z
      mode: "update"
      note: "Replaced silent FIFO batch clamping with grouped-head batching, explicit unsafe-config rejection, and performance gates."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-16T12:51:21Z
      mode: "implement"
      note: "Started M1 by creating upstream adapter plan 7 and coordinating the MasterPlan boundary"
---

# Enforce FIFO group ordering under failure and batched consumption

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current while implementing it. Promote durable conclusions to
the ADR corpus before completion.


## Purpose / Big Picture

`keiro-pgmq` promises that messages sent to the same FIFO group are handled in send order.
That promise is currently false when `FifoThroughput` or `FifoRoundRobin` is combined with a
batch larger than one: PGMQ may lease several members of one group in one read, and both Keiro
consumer paths continue through the leased batch after an earlier member retries or throws.
`runJobOnce` also silently uses unordered reads because ordering lives only in `JobTuning`.

After this work, every accepted configuration has an honest contract. A `Job` declares its
ordering, default entry points adopt it, and explicit tuning that contradicts it is rejected
before the first read. The existing batch-filling FIFO strategies remain available only with
`batchSize = 1`; an unsafe larger value fails loudly instead of being silently clamped. A new
`FifoHeads` strategy uses PGMQ 1.12's `read_grouped_head` operation, which leases at most one
absolute head from each group, so one database call can safely return work from many groups.
This preserves batching without exposing a successor before its group head settles.

The feature is observable in two ways. Correctness tests show that retry, handler exception,
dead-letter, and delayed-head branches never deliver a same-group successor early on either
consumer path. A deterministic trace assertion shows that sixteen distinct groups can be
claimed by one grouped-head read rather than sixteen batch-one reads, and a database benchmark
compares end-to-end safe drains before the new mode is recommended. The plan does not promise
exactly-once processing or parallel handlers: leases can expire, handlers must be idempotent,
and the current drain and `mkProcessor` handler paths are serial.


## Progress

- [x] 2026-09-16: Refreshed repository, dependency, release, and baseline evidence; `cabal test keiro-pgmq-test --test-show-details=direct` passed with 65 examples, 0 failures, and 2 pre-existing pending examples.
- [x] 2026-09-16: Created
  `mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`
  and revised the parent MasterPlan's adapter boundary.
- [x] 2026-09-16: Published `shibuya-pgmq-adapter-0.16.0.0` to Hackage with Haddocks,
  pushed annotated tag `v0.16.0.0`, and published the matching GitHub release after all
  adapter tests, builds, capability checks, package checks, Haddocks, and flake checks passed.
- [x] 2026-09-16: Added `FifoHeads`, the required `Job.jobOrdering` contract, shared validation
  before reads, complete in-repository constructor migration, and the `fifo-heads` DSL surface.
- [x] 2026-09-16: Dispatched one-shot grouped-head reads directly and workers through adapter
  `HeadPerGroup`; added retry, throw, delayed-head, dead-letter, mismatch, sixteen-group batch,
  default-entry-point, legacy batch-one, and continuous-worker regressions. Seven focused
  `FifoHeads` examples pass.
- [x] 2026-09-16: Removed the local adapter overlay and completed Hackage-only validation.
  Cabal's install plan selects `shibuya-pgmq-adapter-0.16.0.0` as a remote-repository tarball;
  the full workspace build, 78-example PGMQ suite (0 failures, 2 pre-existing pending),
  743-example DSL suite (0 failures), focused conformance/ops/example suites, strict 44-concept
  ADR validation, formatting, flake checks, and `git diff --check` all pass.


## Surprises & Discoveries

- The released `pgmq-hasql-0.6.0.0` and `pgmq-effectful-0.6.0.0` APIs already export
  `readGroupedHead` and `readGroupedHeadWithPoll`. Hackage lists 0.6.0.0 and the upstream
  repository has tag `v0.6.0.0`. No pgmq-hs source change or SQL override is needed.
- The latest released `shibuya-pgmq-adapter-0.15.0.0` has only `ThroughputOptimized` and
  `RoundRobin`. Its standard and long-poll branches call `readGrouped` or
  `readGroupedRoundRobin`; there is no grouped-head strategy. Hackage and upstream tag
  `v0.15.0.0` agree. The worker path therefore needs an upstream adapter addition before
  Keiro can use safe multi-group batching.
- Silently clamping every FIFO batch to one would close the correctness hole but introduce a
  database-round-trip regression proportional to message count. It would also erase the
  operator's requested batch size without reporting it. This plan supersedes that design.
- `read_grouped_head` chooses the absolute lowest `msg_id` of each group regardless of
  visibility, then leases only visible heads. An invisible or delayed head blocks its group.
  Messages without `x-pgmq-group` share one implicit group. This is the required selection
  behavior, but the query groups the queue table and must be measured at realistic depths.
- The pending client-side result-order plan
  `mori://shinzui/pgmq-hs/plans/19-give-the-grouped-reads-a-deterministic-return-order` is not
  a correctness dependency here. `FifoHeads` returns at most one message per group, and Keiro
  promises no processing order between different groups. Legacy grouped modes are restricted
  to one returned message, so vector order cannot reorder members of one group.
- The current Mori registry resolves the pgmq-hs project and package URIs but not its plan or
  MasterPlan artifact kinds. The canonical plan URIs in this document are retained intentionally;
  their files were verified through the checkout resolved by `mori path mori://shinzui/pgmq-hs`.
- The complete current set of `Job` record constructions is larger than the prior plan listed:
  `keiro-pgmq/test/Main.hs`, `keiro-ops/src/Keiro/Ops/Pgmq.hs`, `keiro-ops/test/Main.hs`,
  `jitsurei/src/Jitsurei/ShipmentNotices.hs`,
  `keiro-dsl/test/conformance-queue-runtime/Main.hs`, and
  `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`.
- Current documentation says distinct FIFO groups proceed in parallel. The implementation
  does not establish that: `runJobOnceWithContext` uses `foldM`, and Shibuya's `mkProcessor`
  constructs `Unordered` plus `Serial`. The refreshed documentation must say that groups are
  independently eligible and may be claimed together, while handlers remain serial today.
- Shared validation can run before either consumer constructs or invokes its adapter. Invalid
  raw tuning, job/tuning ordering disagreement, and legacy FIFO batches larger than one now
  raise `JobConsumptionConfigError` without emitting a receive span. `withOrdering` preserves
  the requested batch size, so it cannot hide an unsafe legacy deployment.
- Mutation evidence proves both grouped-head dispatch and quantity preservation. Routing
  `FifoHeads` through legacy `readGrouped` made the thrown-head regression observe a same-group
  successor. Forcing grouped-head quantity one made the sixteen-group trace test emit sixteen
  receives instead of one. Restoring `readGroupedHead` and the caller's quantity makes the
  focused suite pass.
- The DSL suite's external GHC probes import `Keiki.Shape` directly. Under the temporary adapter
  overlay, the package became hidden in Cabal's generated environment, so those probes now expose
  their direct `keiki` dependency explicitly rather than relying on accidental environment state.
  The two affected probes pass after the correction.
- The adapter's three-sample matrix passed on an Apple M1 Max with 64 GB RAM and PostgreSQL
  17.10 using only the conventional FIFO GIN index. For 10,000 messages in one group, grouped
  heads at quantities 1/10/50 measured medians 14.794956/14.160436/21.275268 s versus the
  29.953141 s legacy-safe baseline; every case used 10,000 reads because only one head was
  eligible. Across 100 groups, quantities 1/10/50 measured medians
  13.305524/1.595694/0.562668 s and 10,000/1,000/200 reads versus the 77.516639 s legacy
  baseline. Ratios were 0.172/0.021/0.007.
- For 100,000 messages across 10,000 groups, grouped-head quantity one was the safe baseline:
  median 1,044.325426 s, p95 1,128.905983 s, 95.76 messages/s, and 100,000 reads. Quantity ten
  measured median 120.252500 s, p95 127.456734 s, 831.58 messages/s, 10,000 reads, ratio 0.115.
  Quantity fifty measured median 37.467157 s, p95 42.513543 s, 2,669.00 messages/s, 2,000 reads,
  ratio 0.036. Both passed the 20 percent gate. The legacy query was excluded only from this
  fixture after 123 reads took about 20 minutes; smaller fixtures retain the migration baseline.
- A clean Hackage-only whole-workspace build exposed two generated conformance consumers that
  imported both the generated queue policy and `Job(..)` unqualified. Qualifying the generated
  policy fields removes the `jobOrdering` ambiguity and keeps the generated public field name.
- The machine's pre-existing Cabal configuration redirects its insecure Hackage URL to an
  unavailable mirror. Final validation used a temporary repository-local Cabal configuration
  pointed directly at HTTPS Hackage; the global configuration was not changed, and the install
  plan confirms the adapter source is a Hackage tarball rather than a local checkout.


## Decision Log

- Decision: Preserve the requested batch size and reject unsafe legacy FIFO batching rather
  than silently clamping it.
  Rationale: `FifoThroughput` and `FifoRoundRobin` may lease multiple members of one group.
  They are correct only at batch one in Keiro's continue-on-failure consumers. A startup/drain
  exception is visible and actionable; a clamp hides a potentially severe throughput change.
  Date: 2026-09-16

- Decision: Add a distinct `FifoHeads` ordering instead of changing the meaning of
  `FifoRoundRobin`.
  Rationale: Grouped heads lease at most one message from each group, while round-robin reads
  may return several layers from each group. Reusing the old constructor would be an API lie
  and could change query performance for existing correct batch-one deployments. A new
  constructor makes the PGMQ 1.12 requirement and performance choice explicit.
  Date: 2026-09-16

- Decision: Add `HeadPerGroup` to the adapter's exported `FifoReadStrategy` and consume an
  actual release before raising Keiro's bound.
  Rationale: The worker path should continue using the maintained adapter for polling,
  finalization, shutdown, and telemetry. Reimplementing an adapter inside Keiro would duplicate
  reliability logic. The adapter addition is a PVP-significant public sum-type change, so do
  not assume a release number; verify Hackage and the upstream tag at integration time.
  Date: 2026-09-16

- Decision: Carry `jobOrdering :: !JobOrdering` on every `Job`. Default-tuning entry points
  adopt it; explicit-tuning entry points require exact equality.
  Rationale: Ordering is a durable queue contract in the Keiro DSL, not an incidental worker
  preference. A required field makes every old constructor fail to compile until its contract
  is stated. Exact equality also prevents a generated `fifo-heads` contract from being run
  accidentally through a legacy batch-filling operation.
  Date: 2026-09-16

- Decision: Keep `withOrdering` total and make it only replace the ordering field.
  Rationale: Generated `jobTuningFor = withOrdering jobOrdering` remains ergonomic, while a
  shared runtime validator checks positive tuning, job/tuning agreement, and the legacy
  FIFO batch-one rule on both consumption paths. A total setter must not silently alter the
  independent deployment-owned batch-size field.
  Date: 2026-09-16

- Decision: Do not depend on deterministic multirow result ordering or alter PGMQ SQL.
  Rationale: At most one member per group makes cross-group vector order irrelevant to the
  per-group contract. This follows the no-extension-override boundary in
  `mori://shinzui/pgmq-hs/masterplans/5-correct-the-fifo-grouped-read-ordering-index-and-partition-retention-contracts`.
  Optional index work remains in `docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`.
  Date: 2026-09-16

- Decision: Gate the new mode with deterministic statement-count evidence and a same-machine
  database benchmark; do not gate ordinary CI on wall-clock timings.
  Rationale: Trace counts catch accidental query-per-message regressions without flakiness.
  The benchmark catches expensive grouped-head plans at realistic queue depths and group
  cardinalities, while remaining an explicit release artifact rather than a noisy CI test.
  Date: 2026-09-16


## Outcomes & Retrospective

The plan is complete. Every job declares its ordering; unsafe legacy batches and mismatches fail
before reads; `FifoHeads` preserves batching while admitting only one absolute head per group;
and default entry points inherit the job contract. PostgreSQL regressions cover retry, exception,
delay, dead-letter, batch, and worker behavior, including one receive for sixteen independent
groups. The FIFO consumer-contract decision is recorded in ADR-44. The adapter's published
0.16.0.0 release supplies grouped-head dispatch on both polling paths and passed the complete
performance gate. Keiro then built and tested from the Hackage tarball with no source override.


## Context and Orientation

This repository's `keiro-pgmq/src/Keiro/PGMQ/Job.hs` defines typed jobs, producer functions,
queue provisioning, worker construction, and the bounded drain. PGMQ stores messages in
PostgreSQL. Reading a row advances its `vt` visibility timestamp so other readers cannot see
it until the lease expires; deleting or archiving the row advances the group. Delivery is
at-least-once because a lease can expire before settlement.

`JobTuning` currently contains `visibilityTimeout`, `batchSize`, `polling`, and `ordering`.
`JobOrdering` has `Unordered`, `FifoThroughput`, and `FifoRoundRobin`. `adapterConfigFor`
maps tuning into a Shibuya adapter configuration for `jobProcessorWithContext`; the adapter
polls and flattens each returned vector into independent deliveries. `runJobOnceWithContext`
implements its own loop, chooses a PGMQ read from `tuning.ordering`, folds the returned vector
serially, and settles each message. `jobProcessor` and `runJobOnce` currently inject
`defaultJobTuning`, whose ordering is `Unordered`.

The unsafe shape is a same-group batch. Suppose `a1` and `a2` share a group and one grouped
read leases both. If handling `a1` returns `Retry` or throws, the drain still handles `a2`;
the supervised worker similarly finalizes a thrown handler as an immediate retry and moves
to the next delivery. A later database read would be blocked by the invisible head, but that
guard cannot retract `a2` from an already leased vector.

PGMQ 1.12 added `read_grouped_head(queue, vt, qty)`. Its `qty` is a number of groups rather
than a number of same-group members: the function computes the absolute lowest message ID in
each group, filters to visible heads, locks with `SKIP LOCKED`, and leases at most one head per
selected group. `mori://shinzui/pgmq-hs/packages/pgmq-hasql` and
`mori://shinzui/pgmq-hs/packages/pgmq-effectful` expose this in released version 0.6.0.0 as
`readGroupedHead` and `readGroupedHeadWithPoll`, both using the existing `ReadGrouped` argument
records. Keiro already bounds the pgmq-hs family to `>=0.6 && <0.7`.

The worker prerequisite is implemented under
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`.
The relevant files are
project-relative `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs`,
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`, the adapter tests, and
`shibuya-pgmq-adapter-bench/bench/Bench/Fifo.hs`. That plan owns the public constructor,
dispatch tests, database semantics, safe-drain benchmark, documentation, and release.

Adding `FifoHeads` also touches the Keiro DSL because workqueue ordering is a durable generated
contract. `keiro-dsl/src/Keiro/Dsl/Grammar.hs` owns `WqOrdering`;
`keiro-dsl/src/Keiro/Dsl/Parser/Queue.hs` parses the spellings;
`keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` renders them;
`keiro-dsl/src/Keiro/Dsl/Diff.hs` classifies changes; and
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` emits `JobOrdering` constructors and `jobTuningFor`.
Use the spelling `fifo-heads`. Existing `fifo-throughput` and `fifo-roundrobin` syntax remains
source-compatible.

The ADR filenames and headings were re-scanned on 2026-09-16. The directly relevant record is
`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md`: each delivery on both paths has
exactly one Consumer span, acknowledgement attributes appear only after settlement, and a
thrown drain handler has no acknowledgement attribute. Preserve those tests unchanged.
`docs/adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md` was considered but this
plan creates no schema or migration. No existing ADR records the FIFO consumption contract;
create one during M4 if implementation confirms these decisions.

Sibling plan `docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md`
owns DLQ operator behavior. Sibling plan 118 owns optional index measurements and provisioning
claims. This plan must not add or replace PGMQ functions, edit historical migration bytes,
automatically install a supplemental index, or change Shibuya core scheduling.


## Plan of Work

### Milestone 1 — add grouped-head dispatch to the released adapter boundary

Implement
`mori://shinzui/shibuya-pgmq-adapter/plans/7-add-grouped-head-fifo-polling-to-the-pgmq-adapter`,
which was created with this plan's intention after revising the parent MasterPlan boundary.
It preserves the adapter's polling, retry, prefetch, shutdown-release, finalization, and
telemetry contracts.

In the adapter, extend `FifoReadStrategy` with `HeadPerGroup`. In the standard-poll branch,
dispatch it to `Pgmq.Effectful.readGroupedHead (mkReadGrouped config)`; in the long-poll
branch, dispatch it to `readGroupedHeadWithPoll (mkReadGroupedWithPoll config ...)`. Keep
`ThroughputOptimized` and `RoundRobin` unchanged. Update public exports, Haddocks, the advanced
user guide, capability evidence, root/package changelogs, and every exhaustive pattern match.

Add pure/internal tests showing that all three strategies select the intended effect operation
for standard and long polling. Add database integration cases with groups `a` and `b`: a poll
with quantity greater than one returns at most `a1` and `b1`, never `a2` or `b2`; hiding `a1`
blocks only group `a`; deleting `a1` makes `a2` eligible. Assert selection by message IDs and
group subsequences, not cross-group vector order.

Extend `shibuya-pgmq-adapter-bench/bench/Bench/Fifo.hs` with safe end-to-end drain cases. On
the same database and binary, compare legacy grouped quantity one with grouped-head quantities
1, 10, and 50 for these fixtures: 10,000 messages in one group; 10,000 messages across 100
groups; and 100,000 messages across 10,000 groups. Include delete/ack work so the measurement
represents a drain, record read-statement count, throughput, median, and p95, and run with the
conventional FIFO GIN only. An optional supplemental-index run may be reported separately but
must not be required for correctness or silently change plan 118's ownership.

Acceptance for M1 is: adapter tests pass; all components build with tests and benchmarks;
grouped-head quantity N never leases two members of one group; the 100-group fixture uses
materially fewer reads than the quantity-one baseline; and no grouped-head workload is more
than 20 percent slower end-to-end than the safe quantity-one baseline on the same machine.
If the 20 percent gate fails, investigate and record `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`
evidence before release. Do not weaken the threshold or make `FifoHeads` the recommended mode
without documenting the resolved cause.

Release the adapter under the repository's PVP policy. Because adding an exported constructor
can break exhaustive downstream matches, treat it as a breaking API change. Do not write a
guessed version into Keiro. Verify the actual Hackage version and upstream tag, then use that
version in M2.


### Milestone 2 — make the Keiro API reject contradictions and preserve safe batches

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`, add `FifoHeads` to `JobOrdering` and add the required
field `jobOrdering :: !JobOrdering` to `Job`. Document `FifoHeads` as PGMQ 1.12+ grouped-head
selection: `batchSize` bounds groups claimed per read, not messages from one group. Document
that legacy `FifoThroughput` and `FifoRoundRobin` are accepted only at batch one. Remove every
claim that Keiro currently runs handlers from different groups in parallel.

Add and export one exception type that covers all consumption-time configuration failures:

```haskell
data JobConsumptionConfigError
  = InvalidJobTuning !JobTuningConfigError
  | JobOrderingMismatch
      { jobOrderingDeclared :: !JobOrdering,
        tuningOrderingGiven :: !JobOrdering
      }
  | UnsafeLegacyFifoBatch
      { unsafeOrdering :: !JobOrdering,
        unsafeBatchSize :: !Int32
      }
  deriving stock (Eq, Show)
  deriving anyclass (Exception)
```

Implement one internal pure validator and call it at the start of both
`jobProcessorWithContext` and `runJobOnceWithContext`, before adapter construction or a PGMQ
read. It must reject non-positive visibility timeout, batch size, or polling values using the
same rules as `mkJobTuning`; reject tuning whose ordering differs from `job.jobOrdering`; and
reject `batchSize /= 1` for `FifoThroughput` or `FifoRoundRobin`. `Unordered` and `FifoHeads`
accept every positive batch size. Reuse shared predicates so constructor-time and runtime
validation cannot drift. `withOrdering` remains a plain record update and preserves batch size.

Change `jobProcessor` and `runJobOnce` to call their explicit-tuning counterparts with
`withOrdering job.jobOrdering defaultJobTuning`. A FIFO job can no longer be consumed through
plain `pgmq.read` merely because the caller selected the convenience wrapper.

Map `FifoHeads` to `FifoConfig HeadPerGroup` in `toFifoConfig`. Raise
`shibuya-pgmq-adapter`'s lower bound only after M1's version is visible on Hackage and its tag
resolves upstream. Keep the released pgmq-hs 0.6 family bound; no pgmq-hasql result-order bump
or pgmq-migration change is required.

Update all six `Job` construction sites listed in Surprises & Discoveries. General raw jobs in
Keiro Ops and the default test helper declare `Unordered`. Generated FIFO conformance jobs use
their generated `QueuePolicy.jobOrdering`. The shipment-notice example declares the same FIFO
ordering as `shipmentNoticeTuning`. Add a separate FIFO test helper rather than changing the
meaning of the existing unordered `mkJob` helper.

Extend the DSL with `WqFifoHeads` and the spelling `fifo-heads`. Update parser, pretty-printer,
diff rendering, scaffolder output, fixtures, golden/captured generated modules, user reference,
and tests. Ordering changes remain breaking in `keiro-dsl diff`. The generated comment must say
that deployment owns the positive batch size, while the runtime rejects a batch greater than
one for the two legacy batch-filling modes.

Acceptance for M2 is a whole-repository build plus focused pure tests proving: `withOrdering`
does not change the batch; legacy FIFO batch eight is rejected rather than clamped; `FifoHeads`
batch eight is accepted; invalid raw tuning is rejected on both paths; exact job/tuning
ordering mismatches are rejected; and default wrappers adopt the job field.


### Milestone 3 — dispatch heads and pin every failure branch

In the drain's read case, dispatch `FifoHeads` to `readGroupedHead` using the existing
`ReadGrouped` record and `nextBatchSize`. Leave the legacy cases on `readGrouped` and
`readGroupedRoundRobin`; the shared validator guarantees their quantity is one. Do not sort
the returned vector. Cross-group order is not part of the contract, and sorting cannot repair
an unsafe same-group lease.

Add these database-backed examples to `keiro-pgmq/test/Main.hs` using fresh databases and the
existing tracing fixture where stated:

- A `FifoHeads` batch over sixteen groups, with `batchSize = 16` and `n = 16`, handles all
  sixteen heads and emits exactly one PGMQ grouped-head receive span. This is the deterministic
  no-query-per-message performance guard.
- With `a1,a2` in group `a` and `b1,b2` in group `b`, a large head batch contains no more than
  one member per group. Assert per-group subsequences only; do not assert cross-group order.
- If `a1` returns `Retry`, throws, or remains delayed, `a2` is never observed. Work from group
  `b` may continue; that independence is correct. The throw case must retain ADR-1's exception
  and no-ack span behavior.
- If `a1` is dead-lettered, `a2` becomes the next eligible member and is then handled. Assert
  the main-queue and DLQ depths.
- A delayed `a2` blocks `a3` until its visibility time, after which `a2` then `a3` are observed.
- `runJobOnce` on a `FifoHeads` job uses grouped-head reads without explicit tuning. Both
  explicit-tuning entry points throw `JobConsumptionConfigError` before any receive span on a
  mismatch or unsafe legacy batch.
- The continuous worker retries a failed `a1` before observing `a2`. Add a multi-group
  `FifoHeads` worker case to prove the adapter release is actually selected, not merely compiled.
- Preserve batch-one regression coverage for both `FifoThroughput` and `FifoRoundRobin` so a
  future refactor cannot accidentally route them through unordered reads.

Make the tests bite. Temporarily route `FifoHeads` to `readGrouped` and verify the retry/throw
case observes a successor or the at-most-one-per-group assertion fails. Temporarily force its
quantity to one and verify the grouped-head receive-span count assertion fails. Restore both
mutations before committing and record the results in Surprises & Discoveries.

Acceptance for M3 is the expanded `keiro-pgmq-test` suite with zero failures and the same two
pre-existing pending examples, plus unchanged ADR-1 span tests. Record the new example count
in Progress rather than retaining an estimate.


### Milestone 4 — performance, documentation, rollout, and durable context

Run M1's benchmark on the release candidate and retain the command, machine/PostgreSQL details,
fixture sizes, statement counts, median, p95, and throughput in both plans. The deterministic
Keiro trace test must show one receive for sixteen groups. The benchmark must meet the 20 percent
gate and demonstrate fewer statements for multi-group drains. If it does not, leave
`FifoHeads` unrecommended and the plan incomplete until the cause is resolved; do not hide a
regression behind a larger tolerance.

Update `keiro-pgmq/CHANGELOG.md`, `keiro-dsl/CHANGELOG.md`,
`docs/user/work-queues.md`, `docs/guides/work-queues.md`, the DSL reference, and the shipment
notice example. Explain the three distinct facts: legacy FIFO modes require batch one;
`FifoHeads` batches across groups on PGMQ 1.12+; and Keiro's current handlers are serial even
when one read claims several independent group heads. State the rolling deployment order:
deploy consumers that understand the new required `Job` field and `FifoHeads` before changing
generated queue policy or producer assumptions.

Update the parent MasterPlan and `docs/backlog.md` so plan 116 is no longer described as blocked
on deterministic grouped-result ordering. Its actual release dependency is the grouped-head
adapter release. Preserve canonical cross-repository references.

Finally, review this plan's Decision Log, discoveries, and benchmark evidence. Create a FIFO
consumer-contract ADR under the profiled `docs/adr` bundle, allocate its stable ID with `okf id
next`, add its log entry, and run strict validation. The ADR should record accepted read shapes,
runtime validation, PGMQ 1.12 requirement, serial-handler limitation, and why result sorting is
not a correctness mechanism.


## Concrete Steps

Resolve dependency sources through Mori before editing them:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
mori registry show shinzui/pgmq-hs --full
mori registry show shinzui/shibuya-pgmq-adapter --full
mori path mori://shinzui/shibuya-pgmq-adapter
```

In the adapter checkout, create its ExecPlan, implement M1, and run:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
cabal test shibuya-pgmq-adapter-test --test-show-details=direct
cabal build all --enable-tests --enable-benchmarks
just process-up
export PGHOST="$PWD/db"
export PGDATABASE=shibuya_pgmq_adapter
export PG_CONNECTION_STRING="postgresql:///shibuya_pgmq_adapter?host=$(jq -rn --arg x "$PGHOST" '$x|@uri')"
BENCH_MESSAGE_COUNT=10000 BENCH_BATCH_SIZES=1,10,50 \
  cabal bench shibuya-pgmq-adapter-bench --benchmark-options='-p safe-fifo-drain --stdev 10'
```

The benchmark command is safe only against the disposable local `shibuya_pgmq_adapter` database
created by `just process-up`; never point it at a production queue. Add the `safe-fifo-drain`
benchmark pattern as part of M1. Capture a CSV as well if the local tasty-bench version supports
it.

Before selecting the Keiro bound, verify the actual release independently of local source:

```bash
curl -fsSL https://hackage.haskell.org/package/shibuya-pgmq-adapter.json
git ls-remote --tags https://github.com/shinzui/shibuya-pgmq-adapter.git
```

Run the Keiro baseline and focused validations from the Keiro root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build all --enable-tests --enable-benchmarks
cabal test keiro-pgmq-test --test-show-details=direct
cabal test keiro-dsl-test \
  keiro-dsl-conformance-queue \
  keiro-dsl-conformance-queue-runtime \
  keiro-dsl-conformance-dispatch-full \
  keiro-ops-test \
  jitsurei-test \
  --test-show-details=direct
```

The 2026-09-16 baseline is:

```text
65 examples, 0 failures, 2 pending
Test suite keiro-pgmq-test: PASS
```

The pending cases are the existing transient-poll fault-injection placeholder and the live
pg_partman provisioning case. New FIFO cases must not be pending.

When creating the ADR, follow the profiled bundle contract:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Commit each green milestone with Conventional Commits. Every Keiro commit includes both active
trailers; cross-repository adapter commits cite the upstream plan and the same intention if its
frontmatter inherits it:

```text
feat(keiro-pgmq)!: enforce declared FIFO consumption contracts

ExecPlan: docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md
Intention: intention_01m2b1p3vhe179jtr5qz6ghqks
```


## Validation and Acceptance

The plan is complete only when all of these are observable:

1. The released adapter has `HeadPerGroup` standard and long-poll dispatch, Hackage and the
   upstream tag agree on the version, and Keiro's bound selects it without a local source path.
2. Every `Job` declares `jobOrdering`. Default entry points adopt it. Explicit entry points
   reject invalid tuning, mismatches, and legacy FIFO batches larger than one before any read.
3. `FifoHeads` preserves the caller's positive batch size and a sixteen-group drain produces
   one grouped-head receive span, not sixteen receives.
4. Retry, throw, delayed visibility, and dead-letter cases never process a same-group successor
   before its absolute head is settled. Dead-lettering or deleting the head advances the group.
5. Both legacy FIFO strategies retain batch-one correctness tests. Their larger batches fail
   loudly; no code path silently clamps them.
6. The adapter benchmark meets the stated 20 percent end-to-end gate and shows reduced statement
   count for multi-group drains. Results identify machine, PostgreSQL version, queue depth, group
   count, batch size, indexes, median, p95, and throughput.
7. `cabal build all --enable-tests --enable-benchmarks` and all focused suites pass. The final
   `keiro-pgmq-test` count is recorded with zero failures and only the two known pending cases.
8. ADR-1's existing telemetry tests pass unchanged; the new FIFO ADR validates under the strict
   profile; user docs no longer promise parallel handlers or depend on client result sorting.
9. No PGMQ function body, historical migration, automatic supplemental index, or Shibuya core
   scheduling policy changes as part of this plan.


## Idempotence and Recovery

Source edits, builds, tests, and Hackage/tag checks are repeatable. Keiro and adapter integration
tests use disposable PostgreSQL fixtures. The benchmark creates and purges named benchmark
queues in a disposable local database; if interrupted, drop only those explicit benchmark
queues or recreate that disposable database through the adapter repository's normal process
workflow.

The required `Job` field makes a partial source migration fail at compile time. Runtime
validation happens before reads, so an unsafe legacy batch or ordering mismatch does not lease
rows before failing. If the adapter release is unavailable, keep Keiro's dependency bound and
M2-M4 pending; do not commit a machine-local `source-repository-package` or package path.

`FifoHeads` requires PGMQ 1.12 or later. Native pgmq-hs 0.6 installs a compatible schema, but
extension-managed deployments must upgrade before selecting the mode. An undefined-function
failure is not recoverable by retrying the same worker against an older server; roll back the
job policy to a batch-one legacy mode or upgrade the server. No database migration is rolled
back because this plan adds none.


## Interfaces and Dependencies

The intended Keiro surface is:

```haskell
data JobOrdering
  = Unordered
  | FifoThroughput
  | FifoRoundRobin
  | FifoHeads

data Job p = Job
  { jobName :: !Text,
    jobQueue :: !QueueRef,
    jobCodec :: !(JobCodec p),
    jobPolicy :: !RetryPolicy,
    jobOrdering :: !JobOrdering
  }

data JobConsumptionConfigError
  = InvalidJobTuning !JobTuningConfigError
  | JobOrderingMismatch
      { jobOrderingDeclared :: !JobOrdering,
        tuningOrderingGiven :: !JobOrdering
      }
  | UnsafeLegacyFifoBatch
      { unsafeOrdering :: !JobOrdering,
        unsafeBatchSize :: !Int32
      }

withOrdering :: JobOrdering -> JobTuning -> JobTuning
```

`runJobOnce`, `jobProcessor`, `runJobOnceWithContext`, and `jobProcessorWithContext` retain
their signatures. They may throw `JobConsumptionConfigError` through their existing `IOE`
capability. `FifoHeads` maps to the adapter's new `HeadPerGroup`; the drain calls released
`pgmq-effectful-0.6.0.0`'s `readGroupedHead` directly.

The adapter surface adds:

```haskell
data FifoReadStrategy
  = ThroughputOptimized
  | RoundRobin
  | HeadPerGroup
```

The precise adapter version is intentionally not predicted. At refresh time the authoritative
latest releases are pgmq-hs 0.6.0.0 and shibuya-pgmq-adapter 0.15.0.0; only the former already
contains grouped heads. Verify the new adapter release before changing bounds.

Revision note (2026-09-12): Reconciled cross-repository guidance; removed server-migration
assumptions and corrected the client dependency boundary.

Revision note (2026-09-16): Re-audited current Keiro, pgmq-hs 0.6.0.0, Shibuya core, and
shibuya-pgmq-adapter 0.15.0.0. Replaced silent batch clamping and client-result sorting with an
explicit `FifoHeads` mode, shared runtime rejection of unsafe legacy batches, a required job
ordering contract, an adapter release prerequisite, deterministic read-count coverage, and a
database performance gate.

Revision note (2026-09-16): Began implementation by creating upstream adapter plan 7 and
updating MasterPlan 17's boundary before any adapter source changes.

Revision note (2026-09-16): Implemented the required job ordering contract, grouped-head worker
and one-shot dispatch, runtime validation, DSL spelling and scaffolding, adversarial PostgreSQL
coverage, mutation checks, documentation, changelogs, and ADR-44. Adapter release publication and
final Hackage-only validation remain.

Revision note (2026-09-16): Published adapter 0.16.0.0, validated Keiro against its Hackage
tarball with the complete build and test matrix, and marked all milestones complete.
