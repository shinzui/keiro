---
id: 116
slug: enforce-fifo-group-ordering-under-failure-and-batched-consumption
title: "Enforce FIFO group ordering under failure and batched consumption"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
---

# Enforce FIFO group ordering under failure and batched consumption

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-pgmq` documents strict per-group FIFO delivery: when a producer calls
`enqueueToGroup job "customer-42" payload`, every message in group `customer-42` is promised
to be handled in send order, one completing before the next begins. The 2026-07 pgmq review
(master plan: `docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md`)
confirmed adversarially that this promise only actually holds when the consumer reads one
message at a time (`batchSize = 1`). Nothing enforces that, nothing documents it, and a
consumer that opts into `batchSize > 1` silently degrades to best-effort ordering: PGMQ's
`read_grouped` deliberately fills a batch with several messages of the same group, all of
them become claimed simultaneously, and neither consumer path stops handling the rest of a
batch when an earlier member fails. Additionally, an operator script that drains a FIFO
queue with `runJobOnce` (which hardcodes unordered tuning) claims mid-group messages with
plain `pgmq.read`, voiding ordering for every consumer of that queue with no error and no
telemetry. Finally, `read_grouped`'s SQL returns its batch in plan-dependent order because
its final `UPDATE ... RETURNING` has no `ORDER BY`.

After this plan, the FIFO promise is real under every configuration the API accepts:
`withOrdering` pins the batch size to 1 for FIFO orderings and both consumer paths enforce
that floor even against hand-built tuning records; the ordering requirement travels on the
`Job` value itself, so `runJobOnce` on a FIFO job performs grouped reads and an explicit
tuning that contradicts the job's declared ordering fails loudly; the previously untested
failure branches (retry at group head, thrown handler at head, dead-letter at head) and the
never-tested `FifoRoundRobin` strategy are pinned by regression tests on both consumer
paths; and upstream `read_grouped` gains a deterministic return order as defense-in-depth.
You can see it working by running `cabal test keiro-pgmq-test` from the repository root and
reading the new FIFO examples, and by writing a three-message group whose head fails and
observing that the successors never run before the head is settled.


## Progress

- [ ] M1: `withOrdering` clamps batch size to 1 for FIFO orderings; `adapterConfigFor` and the drain's `nextBatchSize` enforce the same floor against raw `JobTuning` records; `JobOrdering` haddock rewritten to state the enforced precondition and delayed-send semantics.
- [ ] M1: New pure examples for the clamp; existing suite green (58 baseline examples still pass).
- [ ] M2: `Job` gains a required `jobOrdering :: JobOrdering` field; all in-repo `Job` record constructions updated (`keiro-pgmq/test/Main.hs`, `keiro-dsl/test/conformance-queue-runtime/Main.hs`, `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`).
- [ ] M2: `runJobOnce`/`jobProcessor` adopt the job's declared ordering; `runJobOnceWithContext`/`jobProcessorWithContext` throw `JobOrderingMismatch` on a conflicting explicit tuning; discriminating tests added.
- [ ] M3: Drain-path FIFO failure-branch tests (retry at head, throw at head, dead-letter at head) pass.
- [ ] M3: Worker-path FIFO failure-branch test passes; first `FifoRoundRobin` tests (drain interleave and worker within-group order) pass; delayed-group-send blocking test passes.
- [ ] M4: pgmq-hs migration `0003` re-creates `pgmq.read_grouped` with a deterministic return order; upstream test added; pgmq-hs family released at 0.4.1.0.
- [ ] M4: keiro-pgmq test-suite bound raised to `pgmq-migration >=0.4.1 && <0.5`; full suite green against the new migration.
- [ ] CHANGELOG entries written for keiro-pgmq (breaking `Job` field) and pgmq-hs; ADR distillation pass done (FIFO delivery contract promoted per the master plan's Integration Points).


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Close the batched-consumption ordering hole (PGQ-1) by enforcing `batchSize = 1`
  as a precondition of FIFO ordering, not by implementing group-abort-on-failure.
  Rationale: Group-abort needs cooperation keiro cannot reach — shibuya's `mkProcessor`
  hardcodes the `Unordered`/`Serial` policies (`shibuya-core/src/Shibuya/Internal/App.hs`
  lines 45-46 in the shibuya repo), its supervised runner substitutes `AckRetry (RetryDelay 0)`
  for a thrown handler and continues (`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`
  around lines 601-614), and the adapter flattens each batch into independent messages —
  and the master plan's Decision Log puts shibuya-core runner changes out of scope. Defaults
  are already `batchSize = 1` everywhere, so the clamp changes no currently-correct
  deployment, and a FIFO group's throughput is inherently head-of-line limited anyway.
  Date: 2026-07-23

- Decision: `withOrdering` stays a total function and clamps (with a loud haddock) rather
  than becoming a validating `Either`.
  Rationale: `withOrdering` is called from generated code — keiro-dsl's scaffolded
  `QueuePolicy` modules emit `jobTuningFor = withOrdering jobOrdering` (see
  `keiro-dsl/test/conformance-queue-runtime/Generated/HospitalCapacity/Reservation_work/QueuePolicy.hs`
  lines 15-21) — and an `Either` return would force error plumbing through every generated
  and hand-written call site for a condition the function can simply make true. The raw
  `JobTuning` constructor remains an escape hatch, which is why both consumption sites also
  enforce the floor (defense-in-depth).
  Date: 2026-07-23

- Decision: The ordering requirement is carried as a new required field
  `jobOrdering :: !JobOrdering` on `Job` (PGQ-7). Default-tuning entry points
  (`runJobOnce`, `jobProcessor`) adopt it; explicit-tuning entry points
  (`runJobOnceWithContext`, `jobProcessorWithContext`) validate the tuning against it and
  throw a new `JobOrderingMismatch` exception on conflict.
  Rationale: The master plan's vision requires the ordering to "travel with the `Job` so an
  ops script cannot silently void it". A required record field makes every existing `Job`
  construction a compile error, which is the loud, greppable migration; a `Maybe` field or a
  smart-constructor default would let stale code keep compiling with the unsafe meaning.
  Adopting (rather than rejecting) on the default-tuning paths turns the dangerous case —
  `runJobOnce` against a FIFO queue — into correct behavior instead of a new failure mode.
  Date: 2026-07-23

- Decision: Upstream, `pgmq.read_grouped` gets a deterministic return order by carrying the
  batch-selection rank through to a final ordered `SELECT`, mirroring `read_grouped_rr`'s
  existing `selection_order` pattern; shipped as a new versioned migration file
  `0003-order-read-grouped-returning.sql` in a pgmq-hs 0.4.1.0 family release, never as an
  edit to `0001-install-v1.11.0.sql`.
  Rationale: pgmq installs are an ordered migration ledger (embedded via
  `pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs`); editing an applied file would
  desynchronize existing databases. Rank order (oldest group first, then send order within
  the group) rather than global `msg_id` order keeps the two grouped-read functions
  symmetric; within a single group the two orders are identical. With the batch-size clamp
  in place this fix is defense-in-depth (per the master plan's Dependency Graph note), so it
  may alternatively ride in the release cut by `docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`
  if that plan lands first.
  Date: 2026-07-23

- Decision: Delayed sends into FIFO groups (`enqueueToGroupWithDelay`) are documented, not
  forbidden.
  Rationale: Re-reading `read_grouped`'s guard (`filtered_groups`, migration SQL lines
  335-345) shows that at the enforced `batchSize = 1` a delayed mid-group member correctly
  blocks its successors: once earlier members are consumed, the delayed message is the
  group's earliest in-flight row below the visible head and the `NOT EXISTS` filter excludes
  the group until the delay expires. The skip-a-delayed-member hole the review found
  (PGQ-2's staggered-visibility case) requires a batch to take multiple members in one read,
  which the clamp forbids. A test pins the blocking behavior so an upstream change would
  surface.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains `keiro-pgmq`, a Haskell
package that gives applications typed background jobs on top of PGMQ. PGMQ is a PostgreSQL
extension-style schema (installed here as plain SQL, no extension) that stores each queue as
a table `pgmq.q_<name>`; "reading" a message means claiming it by setting its `vt`
(visibility timeout — a timestamp before which no other reader will see the row) into the
future and returning the row. Deleting the row acknowledges it; letting `vt` expire
redelivers it.

The package's central module is `keiro-pgmq/src/Keiro/PGMQ/Job.hs`. An application declares
a `Job p` record (name, queue reference, payload codec, retry policy — lines 391-397) and
consumes it one of two ways. The continuous worker path (`runJobWorkers`, lines 796-804)
builds a shibuya processor (`jobProcessorWithContext`, lines 749-765) whose PGMQ adapter
config is derived by `adapterConfigFor` (lines 700-712) and hands it to the shibuya
supervised runtime, which owns polling, an inbox, and finalization. The bounded drain path
(`runJobOnceWithContext`, lines 899-1067) reads PGMQ directly in a loop and settles each
message itself; `runJobOnce` (lines 1075-1087) is its wrapper and currently hardcodes
`defaultJobTuning`. "Tuning" is the `JobTuning` record (lines 320-326): visibility timeout,
batch size, polling cadence, and a `JobOrdering` (lines 309-313) that selects between
`Unordered` (plain `pgmq.read`), `FifoThroughput` (PGMQ's `read_grouped`), and
`FifoRoundRobin` (`read_grouped_rr`). FIFO grouping keys on the reserved JSONB header
`x-pgmq-group`, written by `enqueueToGroup` (lines 550-553) via `groupHeader` (lines
561-563).

The defects this plan fixes, with the evidence locations re-verified on 2026-07-23:

PGQ-1 (HIGH, confirmed). The `JobOrdering` haddock (Job.hs lines 295-307) promises "strict
send order" per group unconditionally, but the guarantee only holds at `batchSize = 1`.
The upstream SQL lives in the pgmq-hs repository at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration/migrations/0001-install-v1.11.0.sql`:
`read_grouped` (lines 293-388) is documented to "return as many messages as possible from
the same message group" (line 292), and its `available_messages` CTE takes up to the full
batch quantity per group in a lateral `LIMIT $1` (lines 346-357) ranked by
`batch_selection`'s `ROW_NUMBER() OVER (ORDER BY group_priority, msg_rank_in_group)` (lines
360-366). The DB-side ordering guard — `filtered_groups`'s `NOT EXISTS` over in-flight
members below the visible head (lines 335-345) — protects only *subsequent* reads; members
returned together in one batch all receive the same new `vt` in one final `UPDATE` (lines
375-382). Once a multi-member batch is out, no consumer layer aborts the group on failure:
the drain fold (`foldM step` at Job.hs line 940) records a thrown handler and continues
(lines 973-979), settles `AckRetry` and continues (lines 980-986 and 1016-1023), and
`outcomeToAck` (lines 1004-1007) can never produce `AckHalt`; the worker path hardcodes the
`Unordered`/`Serial` shibuya policies (`mkProcessor`, shibuya repo
`shibuya-core/src/Shibuya/Internal/App.hs` lines 45-46), substitutes `AckRetry (RetryDelay 0)`
for a throw and continues (`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` around
lines 601-614), and the adapter flattens the batch into a stream of independent messages in
returned order (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` lines 228-233 and
`.../Pgmq/Internal.hs` lines 527-538, both `Unfold.unfoldr Vector.uncons`), releasing
unhandled ones only at shutdown (`releaseMessages`, called from `Pgmq.hs` line 248). No
layer restricts batch size for FIFO: `mkJobTuning` (Job.hs lines 344-349) rejects only
`< 1`, `withOrdering` (lines 351-356) is an unvalidated record update, `adapterConfigFor`
passes `batchSize` straight through, the drain's `nextBatchSize` (lines 943-944) is
`min remaining batchSize`, and the adapter's `validateConfig`
(`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` lines 123-136) checks nothing
about `fifoConfig` against `batchSize`. Defaults are `batchSize = 1` everywhere
(`defaultJobTuning`, lines 328-336), so the bug needs explicit opt-in — but the two existing
FIFO tests (`keiro-pgmq/test/Main.hs` lines 1139-1191) both use batch size 1 with
all-success handlers, and `FifoRoundRobin` has zero tests.

PGQ-2 (partially confirmed, latent). `read_grouped`'s final `UPDATE ... RETURNING` (SQL
lines 375-382) has no `ORDER BY` — the `selected_messages` CTE drops `overall_rank`, and a
CTE's internal `ORDER BY` governs only lock acquisition, not the outer statement's output —
so the returned order is query-plan-dependent. Its sibling `read_grouped_rr` already does
this correctly: it carries `selection_order` through and ends with
`SELECT ... ORDER BY selection_order` (SQL lines 190-194). Nothing downstream restores
order: pgmq-hasql decodes with `D.rowVector` in wire order, the adapter unconses in vector
order, the drain folds in list order; there is no `sortOn` anywhere on the path
(grep-verified). Exploiting it needs `batchSize > 1` *and* a plan that diverges from heap
order, which is why it is an amplifier of PGQ-1 rather than an independent bug — but it
makes the documented order unprovable, so M4 fixes it at the source. The related
staggered-visibility hole (a group in state "member 1 visible, member 2 in-flight or
delayed, member 3 visible" returns members 1 and 3 together, skipping 2) is likewise only
reachable with a multi-member batch, because the guard's `min_msg_id` is computed over
visible rows only (SQL line 311) and blocks only in-flight members below the visible head
(lines 341-343); at batch size 1 the lateral `LIMIT 1` can only take the head.

PGQ-7 (confirmed). Ordering is a property of `JobTuning`, not `Job`. `runJobOnce` (Job.hs
lines 1075-1087) hardcodes `defaultJobTuning`, whose ordering is `Unordered`, so an ops
script or a stale-tuned worker pointed at a FIFO queue issues plain `pgmq.read`, which
happily claims mid-group messages while earlier members are in flight — silently voiding
ordering for all consumers of the queue.

Verified-sound behavior this plan must not regress (the master plan records these as
regression-protected ground truth): batch-size-1 cross-read group blocking including
dead-letter-at-head resume; retry/attempt accounting coherence; DLQ move atomicity (the
worker path is transactional; the drain path's send-then-delete duplicate window is
documented); batch enqueue atomicity with input-order ids; header propagation including
`x-pgmq-group` never being stripped and `mergeTraceHeaders` letting user keys win;
provisioning idempotency; and the one-shot trace contract's seven captured-span examples
(`keiro-pgmq/test/Main.hs` lines 901-1060).

Relevant ADR: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (the only ADR
in `docs/adr/`). It fixes the telemetry contract this plan must preserve: every delivery on
either path runs inside exactly one Consumer-kind span named `<jobName> process` continuing
the producer's W3C trace; `shibuya.ack.decision` is recorded only after the finalizing PGMQ
statement returns; the bounded path records no ack decision for a thrown handler and no
`shibuya.inflight.*` attributes. This plan edits `runJobOnceWithContext` (read-shape and
validation only) and adds tests around the drain — it must not add, remove, split, or
reorder spans, and the seven captured-span examples must stay green unmodified.

Sibling plans (do not duplicate their work): the DLQ operator path is
`docs/plans/117-preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe.md`;
provisioning and the FIFO index are
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`. Plan 118
shares the pgmq-hs release train with this plan's M4 (see the master plan's Integration
Points): whichever lands first establishes the new migration file and the other appends the
next numbered file.


## Plan of Work

### Milestone 1 — enforce batch size 1 for FIFO orderings and tell the truth in the docs

Scope: make `batchSize = 1` an enforced precondition of FIFO ordering on every layer keiro
controls, without changing any currently-correct configuration (all defaults are already 1).
At the end of this milestone a consumer physically cannot get a multi-member FIFO batch
through keiro-pgmq, even by building a raw `JobTuning`, and the haddocks say exactly what is
guaranteed and why.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. Rewrite the `JobOrdering` haddock (lines 295-307). State that per-group strict send-order
   delivery is guaranteed *because* keiro enforces one-at-a-time consumption for FIFO
   orderings: `withOrdering` pins the batch size to 1, and both consumer paths floor the
   read quantity to 1 for FIFO orderings even if a raw `JobTuning` says otherwise. Explain
   the mechanism a maintainer needs to preserve it: PGMQ's grouped reads deliberately fill a
   batch from one group, and once several members of a group are claimed together nothing
   aborts the group when an earlier member fails, so multi-member batches would break
   ordering. Document delayed sends into a group (`enqueueToGroupWithDelay`): a delayed
   member does not lose its place — successors sent later are blocked by the database guard
   until the delayed member becomes visible and is consumed (M3 pins this with a test).
   Keep the existing at-least-once/idempotency sentence.

2. Change `withOrdering` (lines 351-356) so that choosing `FifoThroughput` or
   `FifoRoundRobin` also sets `batchSize = 1`:

   ```haskell
   -- | Set the FIFO read strategy on an existing tuning. Selecting
   -- 'FifoThroughput' or 'FifoRoundRobin' also clamps 'batchSize' to 1:
   -- one-at-a-time consumption is the precondition of the strict per-group
   -- ordering guarantee (see 'JobOrdering'), and both consumer paths enforce
   -- the same floor at the read site. Selecting 'Unordered' leaves the batch
   -- size untouched.
   withOrdering :: JobOrdering -> JobTuning -> JobTuning
   withOrdering Unordered tuning = tuning{ordering = Unordered}
   withOrdering o tuning = tuning{ordering = o, batchSize = 1}
   ```

3. Add a small internal helper next to `adapterConfigFor` and use it in both consumption
   sites (the raw `JobTuning` constructor is exported and unvalidated, so the clamp in
   `withOrdering` alone is insufficient):

   ```haskell
   -- | The read quantity actually used for a tuning: FIFO orderings are floored
   -- to one message per read, the precondition of the ordering guarantee.
   effectiveBatchSize :: JobTuning -> Int32
   effectiveBatchSize tuning = case tuning.ordering of
       Unordered -> tuning.batchSize
       FifoThroughput -> 1
       FifoRoundRobin -> 1
   ```

   In `adapterConfigFor` (lines 700-712), set `batchSize = effectiveBatchSize tuning`. In
   `runJobOnceWithContext`'s `nextBatchSize` (lines 943-944), replace `tuning.batchSize`
   with `effectiveBatchSize tuning`. Note the drain's FIFO reads pass `qty` (lines 923-936),
   which comes from `nextBatchSize`, so this single change covers both grouped read calls.

In `keiro-pgmq/test/Main.hs`, extend the existing "validates job tuning" example (around
line 380) or add sibling pure examples: `withOrdering FifoThroughput` on a tuning with
`batchSize = 8` yields `batchSize = 1`; `withOrdering FifoRoundRobin` likewise;
`withOrdering Unordered` leaves `batchSize` untouched. These need no database.

Acceptance: `cabal test keiro-pgmq-test` from the repository root is green with the new
examples added and no existing example changed. This milestone is deliberately free of
behavior change for every configuration that was previously correct.

### Milestone 2 — carry the ordering on the Job and validate every entry point (PGQ-7)

Scope: after this milestone a `Job` value states its queue's consumption ordering, the
default-tuning entry points honor it, and an explicit tuning that contradicts it fails
loudly instead of silently voiding FIFO. This is a deliberate breaking API change (compile
error at every `Job` construction), which is the migration mechanism: every consumer must
state an ordering once.

In `keiro-pgmq/src/Keiro/PGMQ/Job.hs`:

1. Add the field to `Job` (lines 391-397), documented as the queue's contract rather than a
   consumer preference:

   ```haskell
   data Job p = Job
       { jobName :: !Text
       , jobQueue :: !QueueRef
       , jobCodec :: !(JobCodec p)
       , jobPolicy :: !RetryPolicy
       , jobOrdering :: !JobOrdering
       -- ^ How this queue must be consumed. 'Unordered' for plain queues.
       -- For FIFO queues this must match the ordering producers assume when
       -- they call 'enqueueToGroup': every consumer entry point either adopts
       -- it ('runJobOnce', 'jobProcessor') or validates an explicit tuning
       -- against it and throws 'JobOrderingMismatch' on conflict.
       }
   ```

2. Add the exception and export it:

   ```haskell
   -- | An explicit 'JobTuning' contradicted the ordering declared on the 'Job'.
   -- Consuming a FIFO queue with unordered reads (or vice versa) silently
   -- destroys the per-group ordering guarantee for every consumer of the
   -- queue, so the mismatch is refused loudly instead.
   data JobOrderingMismatch = JobOrderingMismatch
       { jobOrderingDeclared :: !JobOrdering
       , tuningOrderingGiven :: !JobOrdering
       }
       deriving stock (Show)
       deriving anyclass (Exception)
   ```

3. In `runJobOnceWithContext` and `jobProcessorWithContext`, before any read or adapter
   construction, compare `tuning.ordering` with `job.jobOrdering` and
   `liftIO (throwIO (JobOrderingMismatch job.jobOrdering tuning.ordering))` when they
   differ (`jobProcessorWithContext` already throws `JobAdapterConfigInvalid` via `throwIO`,
   so this matches the module's existing error style; both functions carry `IOE :> es`).

4. Make the default-tuning wrappers adopt the declared ordering instead of hardcoding
   `Unordered`: `runJobOnce` (lines 1075-1087) and `jobProcessor` (lines 772-783) pass
   `withOrdering job.jobOrdering defaultJobTuning` instead of `defaultJobTuning`. Because
   M1's `withOrdering` clamps, this is automatically batch-size-safe. Update both haddocks:
   `runJobOnce` no longer means "unordered drain", it means "drain this job the way the job
   declares".

5. Update every in-repo `Job` construction (the compiler will list them; these are the known
   sites): `keiro-pgmq/test/Main.hs` `mkJob` (lines 131-138) gains
   `jobOrdering = Unordered`, and the FIFO examples need jobs with
   `jobOrdering = FifoThroughput` (add a `mkFifoJob` helper next to `mkJob` rather than
   editing `mkJob`'s meaning); `keiro-dsl/test/conformance-queue-runtime/Main.hs` (line 37)
   sets `jobOrdering = QueuePolicy.jobOrdering` — the scaffolded policy module already
   exports exactly this value (`Generated/HospitalCapacity/Reservation_work/QueuePolicy.hs`
   lines 15-16), which is the intended wiring for DSL-generated services;
   `keiro-dsl/test/conformance-dispatch-full/HospitalCapacity/ReservationWork/WorkqueueJob.hs`
   (lines 25-34) likewise imports `jobOrdering` from its `QueuePolicy` module. No keiro-dsl
   scaffolder (`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) change is needed: the generator does
   not emit `Job` records, only the policy pieces users assemble; verify this by building
   `cabal build all` and running the keiro-dsl conformance suites.

New tests in `keiro-pgmq/test/Main.hs`:

- "runJobOnce on a FIFO job performs grouped reads". This discriminates old from new
  behavior deterministically: enqueue `a1` then `a2` into one group on a FIFO job; call
  `runJobOnce 2 job` with a handler that answers `Retry (RetryDelay 5)`. The first read
  claims the group head `a1` and hides it; the second loop iteration's *grouped* read finds
  the group blocked (in-flight head) and the drain returns 1 having handled only `a1`, with
  queue length still 2. Under the old hardcoded-unordered behavior the second read would
  have delivered `a2`. Assert the handler saw exactly `["a1"]`.
- "an explicit tuning that contradicts the job's ordering is refused": call
  `runJobOnceWithContext defaultJobTuning 1 fifoJob ...` and assert it throws
  `JobOrderingMismatch` (use `shouldThrow` with a predicate on the two fields); same for
  `jobProcessorWithContext`.

Acceptance: `cabal build all` compiles the whole repository; `cabal test keiro-pgmq-test`
is green including the two new examples; the keiro-dsl conformance suites still pass
(`cabal test keiro-dsl-test` — use the test-suite names from `keiro-dsl/keiro-dsl.cabal` if
they differ).

### Milestone 3 — pin the failure branches and FifoRoundRobin on both paths

Scope: the missing regression tests. Every ordering-relevant failure branch and the
never-tested round-robin strategy get an example that fails on any future regression of the
cross-read group blocking or of the M1/M2 enforcement. All tests use the suite's existing
fixtures (`Postgres.withFreshDatabase`, `runDb`, `mkFifoJob` from M2, `waitUntil` and
`stopAppQuickly` for the worker path — all already present in `keiro-pgmq/test/Main.hs`).

Drain-path examples (each: `ensureOrderedJobQueue`, enqueue `a1`,`a2` — plus `b1` where
noted — via `enqueueToGroup`, then `runJobOnceWithContext` with
`withOrdering FifoThroughput defaultJobTuning`):

- "FIFO drain does not deliver successors while the head retries": handler returns
  `Retry (RetryDelay 5)` for `a1`. Drain with `n = 2` returns 1; the observation log is
  exactly `["a1"]`; queue length is still 2 (head hidden, successor blocked).
- "FIFO drain leaves the group blocked after a thrown handler at the head": handler throws
  for `a1`. Drain returns 0 (thrown deliveries are not counted); log is `["a1"]`; queue
  length 2. This also re-pins the ADR-0001 branch: the throw records an exception and no
  acknowledgement (the existing captured-span example at test line 1005 already asserts the
  span side; this example asserts the ordering side).
- "FIFO drain resumes the group after dead-lettering the head": handler answers
  `Dead "poison"` for `a1` and `Done` otherwise. Drain with `n = 2` returns 2; log is
  `["a1", "a2"]` in order; DLQ length 1; main queue empty. This is the
  dead-letter-at-head-resume behavior the review verified sound at batch size 1 — now
  test-pinned.

Worker-path example: "worker path holds back FIFO successors until the head succeeds".
Start `runJobWorkers` on a FIFO job whose handler fails `a1` with `Retry (RetryDelay 1)` on
its first delivery (track with an `IORef`) and succeeds on redelivery. `waitUntil` the log
contains three entries, stop the app, and assert the log is `["a1", "a1", "a2"]` — `a2`
never runs before `a1` succeeds. Follow the shape of the existing worker FIFO test (lines
1160-1191), including `mkJobTuning 30 1 (PollEvery 0.1)`.

FifoRoundRobin examples (first coverage ever):

- "FifoRoundRobin drain interleaves groups and preserves within-group order": enqueue
  `a1`, `a2` to group `a` and `b1`, `b2` to group `b` (in the order a1, a2, b1, b2), drain 4
  with `withOrdering FifoRoundRobin defaultJobTuning`, all-`Done`. Assert full drain and
  that the per-group subsequences are `["a1","a2"]` and `["b1","b2"]`. Do not pin the exact
  interleaving: at batch size 1 the observed sequence is a1, b1, a2, b2 with the current
  SQL, but the round-robin layering across groups is an upstream fairness detail, not part
  of keiro's ordering contract — asserting only per-group order keeps the example stable.
- "FifoRoundRobin worker path preserves within-group order": mirror of the existing
  `FifoThroughput` worker test with `FifoRoundRobin`, three messages in one group.

Delayed-send example: "a delayed FIFO member blocks its successors until it becomes
visible": `enqueueToGroup a1`, `enqueueToGroupWithDelay job 2 "a" a2`, `enqueueToGroup a3`.
First drain (n = 3, all-`Done`): returns 1 and the log is `["a1"]` — `a3` is blocked by the
guard because the delayed `a2` is the earliest in-flight member below the visible head.
Sleep past the delay (`threadDelay 2_500_000`), drain again: log becomes
`["a1","a2","a3"]`. This pins the semantics decision recorded in the Decision Log.

Acceptance: `cabal test keiro-pgmq-test` green; deliberately breaking the M1 floor (for
example, temporarily reverting `nextBatchSize` to `tuning.batchSize` and running the retry
example with a raw `JobTuning{batchSize = 8, ordering = FifoThroughput, ...}`) makes the
retry-at-head example fail, demonstrating the tests bite.

### Milestone 4 — deterministic return order for read_grouped, upstream

Scope: the defense-in-depth fix for PGQ-2, in the pgmq-hs repository at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. At the end,
`pgmq.read_grouped` returns its rows in selection-rank order under every query plan, an
upstream test asserts it, the pgmq-hs family is released as 0.4.1.0, and keiro-pgmq's
test-suite depends on the new migration. Coordinate with
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`: if 118's
release lands first, add this function change as the *next* numbered migration file in the
same repo instead of `0003`, and skip the version bump here (state the actual version in
Progress when known).

1. Create `pgmq-migration/migrations/0003-order-read-grouped-returning.sql` containing a
   single `CREATE OR REPLACE FUNCTION pgmq.read_grouped(queue_name TEXT, vt INTEGER, qty INTEGER) ...`
   whose body is byte-for-byte the existing body from `0001-install-v1.11.0.sql` lines
   293-388 with exactly three changes, mirroring `read_grouped_rr`'s `selection_order`
   pattern (lines 117-200 of the 0001 file): `selected_messages` selects
   `msg_id, overall_rank` (not just `msg_id`); the final statement becomes a CTE
   `updated_messages AS (UPDATE ... RETURNING m.msg_id, m.read_ct, m.enqueued_at, m.last_read_at, m.vt, m.message, m.headers, sm.overall_rank)`;
   and the function ends with
   `SELECT msg_id, read_ct, enqueued_at, last_read_at, vt, message, headers FROM updated_messages ORDER BY overall_rank;`.
   Add the filename to `pgmq-migration/migrations/manifest` (the embedded ledger in
   `pgmq-migration/src/Pgmq/Migration/Internal/Definition.hs` picks it up at compile time;
   the schema contract in `pgmq-migration/src/Pgmq/Migration/SchemaContract.hs` needs no
   change because the function's signature is unchanged).
2. Add an upstream test in `pgmq-hasql/test/AdvancedOpsSpec.hs` next to `testReadGrouped`
   (line 292): enqueue five messages into one group, `readGrouped` with `qty = 5`, assert
   the returned `msg_id`s are strictly ascending (within one group, rank order equals
   `msg_id` order). Run the pgmq-hs suite from the pgmq-hs repo root: `just process-up`
   (starts the process-compose Postgres) then `cabal test all`.
3. Bump the five pgmq-hs package versions from 0.4.0.1 to 0.4.1.0 (the family releases in
   lockstep; keiro consumed it that way in commit `ef0b246`), write the pgmq-hs CHANGELOG
   entries, and release through the same internal package index the previous upgrade used.
   Verify what the index actually serves before pinning (per the mori guidance in this
   environment: the local corpus may lag the registry).
4. In `keiro-pgmq/keiro-pgmq.cabal`, raise the test-suite bound to
   `pgmq-migration >=0.4.1 && <0.5` (line 95 today). The library bounds on
   `pgmq-effectful`/`pgmq-hasql`/`pgmq-config`/`pgmq-core` stay `>=0.4 && <0.5` — the
   Haskell API is unchanged; the behavior lives in the migration the test-suite embeds and
   deployments apply. Then from the keiro repo root run `cabal update` (or the dev shell's
   reindex step) and `cabal test keiro-pgmq-test`.

Acceptance: pgmq-hs suite green including the new ordering test; keiro-pgmq suite green on
the new migration with zero test edits (the migration is transparent to keiro's clamped
batch-size-1 reads — that transparency is itself the "defense-in-depth, not load-bearing"
property the master plan describes).


## Concrete Steps

All keiro commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`; all
pgmq-hs commands run from `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`.

Baseline before any edit (the suite starts its own PostgreSQL via keiro-test-support; no
external database is needed):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-pgmq-test
```

Expected tail of the baseline transcript:

```text
58 examples, 0 failures, 2 pending
Test suite keiro-pgmq-test: PASS
```

The two pending examples are pre-existing (`test/Main.hs` lines 645 and 1096: a shibuya
fault-injection placeholder and the pg_partman live-provisioning example) and stay pending
throughout this plan.

Per milestone: make the edits described above, then re-run the same command. After M2 also
run the whole-repo build and the keiro-dsl suites, because the `Job` field is a breaking
change:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal build all
cabal test keiro-pgmq-test
```

For M4, in the pgmq-hs repository:

```bash
cd /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
just process-up
cabal test all
```

then back in keiro after the release and bound bump:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal update
cabal test keiro-pgmq-test
```

Commit at every green milestone using Conventional Commits, for example:

```text
feat(keiro-pgmq)!: carry consumption ordering on Job and enforce FIFO batch-size-1
```

(the `!` belongs on the M2 commit; M1 and M3 are non-breaking `fix(keiro-pgmq)`/
`test(keiro-pgmq)` commits; M4 upstream is its own commit in pgmq-hs plus a
`chore(deps)` bump commit in keiro).


## Validation and Acceptance

The plan is done when all of the following are observable:

1. From the repo root, `cabal test keiro-pgmq-test` prints `0 failures, 2 pending` with the
   example count grown from 58 by the new examples (M1 clamp examples, M2's two entry-point
   examples, M3's seven ordering examples — final count recorded in Progress when known).
2. Constructing FIFO tuning can no longer express a multi-member batch:
   `withOrdering FifoThroughput (defaultJobTuning{batchSize = 8})` evaluates with
   `batchSize == 1` (pinned by an M1 example).
3. A three-message FIFO group whose head fails behaves observably correctly on both paths:
   with a retrying head, successors are not delivered (drain returns 1, queue length intact);
   with a dead-lettered head, the successor is delivered next and in order. These are the M3
   examples; each fails against the pre-plan code if the enforcement or the DB guard is
   broken.
4. `runJobOnce n fifoJob handler` demonstrably uses grouped reads (the M2 discriminator
   example), and `runJobOnceWithContext defaultJobTuning n fifoJob handler` throws
   `JobOrderingMismatch`.
5. The seven ADR-0001 captured-span examples (`test/Main.hs` lines 901-1060) pass
   *unmodified* — the plan's constraint is that no drain change touches span count, names,
   attributes, or the ack-after-settle rule.
6. Upstream, the pgmq-hasql example proves `read_grouped` returns ascending `msg_id`s for a
   single-group batch of five, and `git log` in pgmq-hs shows the 0.4.1.0 release with
   migration `0003-order-read-grouped-returning.sql` in the manifest.


## Idempotence and Recovery

Every keiro-side edit is an ordinary source change guarded by the test suite; re-running any
milestone's steps is safe. The test suite provisions a fresh cloned database per example, so
no state leaks between runs or between failed and successful attempts.

The M2 breaking change is self-announcing: any missed `Job` construction site fails to
compile, and `cabal build all` enumerates them; there is no way to end up half-migrated at
runtime.

The upstream migration is append-only: a new file plus a manifest line, never an edit to an
applied migration. If the migration file needs correction *before* the 0.4.1.0 release is
consumed anywhere, amend it and re-run the pgmq-hs suite (the suite installs the ledger from
scratch). After the release is consumed, treat the file as immutable and ship any fix as the
next numbered migration. If M4 must be abandoned or deferred (for example, handed to
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`'s release per
the Decision Log), milestones 1-3 stand alone: the clamp makes the unordered RETURNING
unreachable through keiro, which is exactly the master plan's fallback posture. Record the
handoff in this plan's Decision Log and in Progress.


## Interfaces and Dependencies

At the end of the plan, `keiro-pgmq/src/Keiro/PGMQ/Job.hs` exports (new or changed surface
only; module is `Keiro.PGMQ.Job`, re-exported through `Keiro.PGMQ`):

```haskell
data Job p = Job
    { jobName :: !Text
    , jobQueue :: !QueueRef
    , jobCodec :: !(JobCodec p)
    , jobPolicy :: !RetryPolicy
    , jobOrdering :: !JobOrdering  -- new, required
    }

data JobOrderingMismatch = JobOrderingMismatch
    { jobOrderingDeclared :: !JobOrdering
    , tuningOrderingGiven :: !JobOrdering
    }  -- instance Exception; thrown by the explicit-tuning entry points

withOrdering :: JobOrdering -> JobTuning -> JobTuning  -- clamps batchSize to 1 for Fifo*
```

`runJobOnce`, `jobProcessor`, `runJobOnceWithContext`, `jobProcessorWithContext` keep their
signatures; their ordering behavior changes as described in M2. `effectiveBatchSize` stays
internal.

Dependencies: `pgmq-effectful`/`pgmq-hasql` (the `readGrouped`/`readGroupedRoundRobin`
operations and `ReadGrouped` record the drain already uses), `shibuya-core` and
`shibuya-pgmq-adapter` (unchanged — this plan deliberately requires no shibuya release; the
worker path becomes safe purely because keiro never hands the adapter a FIFO config with
`batchSize > 1`), and the pgmq-hs family at 0.4.1.0 for M4 with the keiro-pgmq test-suite
bound `pgmq-migration >=0.4.1 && <0.5`. The keiro-dsl package participates only as a
consumer whose conformance fixtures gain the `jobOrdering` field wiring from their generated
`QueuePolicy` modules.
