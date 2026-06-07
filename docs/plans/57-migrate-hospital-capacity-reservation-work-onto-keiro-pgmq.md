---
id: 57
slug: migrate-hospital-capacity-reservation-work-onto-keiro-pgmq
title: "Migrate hospital-capacity reservation work onto keiro-pgmq"
kind: exec-plan
created_at: 2026-06-07T17:25:21Z
intention: "intention_01kthhpasxesx8hp84264cjhpx"
master_plan: "docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md"
---

# Migrate hospital-capacity reservation work onto keiro-pgmq

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The `hospital-capacity` service inside `keiro-runtime-jitsurei` uses a PostgreSQL message
queue for transient work: when an incident declares a patient transfer need, a keiro
`Router` fans the need out to candidate hospitals, enqueuing one "reservation work" item per
candidate. A one-shot consumer drains the queue, turns each item into a
`RequestTransferReservation` command, and appends events to a private aggregate; failures
retry (5s) or land in a dead-letter queue (DLQ) after three attempts. All of this is wired
by hand in one large module, `WorkQueue.hs`, directly against `pgmq-effectful` and
`shibuya-pgmq-adapter`.

This plan replaces that hand-wired plumbing with the `keiro-pgmq` package's typed `Job`
abstraction (built by
`docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md`, a hard
prerequisite). After this plan, the reservation work queue is a single `Job
ReservationWorkItem` declaration plus a domain handler of type
`ReservationWorkItem -> Eff es JobOutcome` (`JobOutcome = Done | Retry delay | Dead reason`);
the producer calls `enqueue`; the one-shot consumer uses `runJobOnce`. The observable win:
`WorkQueue.hs` shrinks to a `Job` value, a producer call, and a domain handler — no more
manual `PgmqAdapterConfig`, `Ingested -> AckDecision` decoding, or `Pgmq : Tracing : Error :
IOE` stack assembly — while the reservation-dispatch behavior, the 5s retry, and the
3-attempt DLQ routing all stay identical.

This migration is the proving ground for the package's **one-shot drain** cadence and its
**DLQ + maxRetries** policy path — the complement to the continuous multi-processor cadence
that the rei migration exercises (`docs/plans/56-...`).


## Progress

- [x] Milestone 1: Add the `keiro-pgmq` pin to keiro-runtime-jitsurei and confirm it resolves.
  (2026-06-07 — jitsurei commit `60a87c8`; bumped keiro `file://` pins to `cb252e2`, added a
  keiro-pgmq stanza; `cabal build hospital-capacity` builds keiro-pgmq-0.1.0.0.)
- [x] Milestone 2: Declare `reservationWorkJob` and port the producer to `enqueue`.
  (2026-06-07 — jitsurei commit `c89338b`, combined with M3.)
- [x] Milestone 3: Port the consumer to `runJobOnce` and the handler to `... -> JobOutcome`.
  (2026-06-07 — jitsurei commit `c89338b`; handler is
  `ReservationWorkItem -> Eff es JobOutcome`, consumer uses `runJobOnce 1`, IdentitySpec
  updated.)
- [x] Milestone 4: Delete dead plumbing; verify reservation-dispatch parity (incl. DLQ).
  (2026-06-07 — jitsurei commit `04420ed`; dead plumbing removed in `c89338b`, unused
  `shibuya-pgmq-adapter` direct dep dropped. `cabal build` + test suite pass; cleanup grep on
  `WorkQueue.hs` is clean. Live CLI happy/DLQ run is the remaining operator step — see
  Outcomes.)


## Surprises & Discoveries

- 2026-06-07 (M1) — **keiro-runtime-jitsurei was pinned at a pre-keiro-pgmq keiro SHA
  (`ac197da`).** keiro-pgmq landed at `cb252e2`, so the keiro `file://` pins (keiro,
  keiro-core) had to be bumped to `cb252e2` before the package was reachable. Verified the
  `ac197da..cb252e2` range only adds `keiro-pgmq/` and `docs/` (plus keiro's own
  cabal.project/mori.dhall), so keiro/keiro-core libraries are byte-identical and the bump is
  safe. Unlike rei (EP-2), **jitsurei was already on shibuya 0.7.0.0 / pgmq 0.3.0.0**, so the
  shibuya-0.7 precondition that blocked EP-2 was already satisfied here — no eventing-stack
  upgrade needed.

- 2026-06-07 (M2/M3) — **A test couples to the old `AckDecision` mapping; the malformed-DLQ
  fixture must stay on raw `sendMessage`.** `services/hospital-capacity/test/IdentitySpec.hs`
  asserts `reservationWorkFailureAck`'s `AckDecision` outputs. Migrating means replacing that
  with `reservationWorkFailureOutcome :: ReservationWorkFailure -> JobOutcome` and updating the
  test to pattern-match `JobOutcome` (which has no `Eq`). Separately,
  `enqueueMalformedReservationWorkWithTelemetry` deliberately enqueues a payload that is NOT a
  valid `ReservationWorkItem` (to exercise the DLQ), so it cannot go through
  `enqueue reservationWorkJob` (which requires a typed item) — it keeps a raw `Pgmq.sendMessage`
  to `reservationWorkJob.jobQueue.physicalName`. `SendMessage` is not in this plan's M4
  cleanup grep, so this is within parity scope.


## Decision Log

- Decision: Preserve the exact failure→outcome mapping: store failure → `Retry (RetryDelay
  5)`; command rejected → `Dead`; decode failure → handled by the package (DLQ).
  Rationale: Behavioral parity. Today `reservationWorkFailureAck` maps `ReservationWorkStoreFailed`
  → `AckRetry (RetryDelay 5)`, `ReservationWorkCommandRejected` → `AckDeadLetter (PoisonPill)`,
  `ReservationWorkDecodeFailed` → `AckDeadLetter (InvalidPayload)`. The first two are domain
  outcomes (map to `Retry`/`Dead`); the decode case is now the package's responsibility.
  Date: 2026-06-07

- Decision: Keep the pre-enqueue idempotency check (querying both the queue and the
  `transfer_decisions` table) in the service; do not push it into the package.
  Rationale: That check is application-specific (it consults a domain table). The package
  offers no dedup store; the service keeps `reservationWorkPendingOrDecided` as-is and calls
  `enqueue` only for items that pass it.
  Date: 2026-06-07

- Decision: Migrate `WorkQueue.hs`'s producer and consumer in one commit (Milestones 2+3),
  then prune dependencies in a second (Milestone 4).
  Rationale: It is a single tightly-coupled module; splitting producer from consumer leaves
  warning-laden intermediate states (unused imports/bindings) with no behavioural value. Each
  commit still leaves the tree building and the test suite green: commit 1 fully migrates the
  module + updates the test, commit 2 drops the now-unused `shibuya-pgmq-adapter` direct dep.
  Date: 2026-06-07

- Decision: Derive `reservationWorkQueueNameText`/`reservationWorkDlqNameText` from
  `reservationWorkJob.jobQueue` via `queueNameToText`, rather than keeping hand-written string
  literals.
  Rationale: Makes the `Job`'s `queueRef "hospital_capacity.reservation_work"` the single
  source of the physical + DLQ names; the existing test asserting the literal strings then
  also proves `queueRef` derives exactly those names.
  Date: 2026-06-07


## Outcomes & Retrospective

Completed 2026-06-07. The `hospital-capacity` reservation-work queue now runs entirely through
`keiro-pgmq`. `WorkQueue.hs` shrank from ~370 lines of hand-wired
`pgmq-effectful` + `shibuya-pgmq-adapter` plumbing to a `Job` declaration, a literal
`JobCodec` over the existing JSON, a `ReservationWorkItem -> Eff es JobOutcome` handler, and
producer/consumer wrappers that call `enqueue` / `ensureJobQueue` / `runJobOnce`. The manual
`PgmqAdapterConfig`, the `Ingested -> AckDecision` decode/dispatch, and the
`pgmqAdapter` + `Stream.take` + `runWithMetrics` consumer are gone, and the direct
`shibuya-pgmq-adapter` dependency was dropped.

Behaviour is preserved by construction: `queueRef "hospital_capacity.reservation_work"`
derives the exact physical + `_dlq` names the service built by hand; the JSON codec is the
unchanged, test-covered `reservationWorkItemToValue`/`FromValue`; the DLQ policy
(`maxRetries = 3`, `directDeadLetter`, 5s retry) is reproduced via `RetryPolicy`; and
`runJobOnce 1` reproduces the old `Stream.take 1` one-shot drain (EP-1 confirmed `runJobOnce`
is implemented exactly that way). The failure→outcome mapping is preserved:
store-failure → `Retry 5`, command-rejected → `Dead`, internal decode → `Dead`, with the
package now owning actual payload-decode dead-lettering.

Verification status:

- **Automated (done):** `cabal build hospital-capacity` succeeds; the `hospital-capacity-test`
  suite passes (including the rewritten `reservationWorkFailureOutcome` assertions); the M4
  cleanup grep on `WorkQueue.hs` is clean.
- **Operator step (remaining):** the live CLI happy-path
  (`reservation-work setup` → `enqueue-latest` → `consume once` → `TransferReservationCreated`)
  and the DLQ path (malformed fixture → consume → row in
  `pgmq.q_hospital_capacity_reservation_work_dlq`) require a provisioned Postgres+PGMQ and the
  connection-string env var, so they are a manual run rather than part of the repo's test
  suite (which is pure). This is well-grounded: `keiro-pgmq`'s own EP-1 integration test
  already proves enqueue → consume → Done/Retry/Dead and DLQ routing against an ephemeral
  Postgres with PGMQ, and the queue names / codec / policy here are identical to before.

What differed from the plan: jitsurei was pinned at a pre-keiro-pgmq keiro SHA, so M1 required
bumping the keiro `file://` pins (not just adding one stanza); it was already on shibuya 0.7,
so unlike rei no eventing-stack upgrade was needed. M2 and M3 were committed together (one
tightly-coupled module). A unit test coupled to the old `AckDecision` mapping had to be
migrated to `JobOutcome`, and the malformed-DLQ fixture intentionally keeps a raw
`sendMessage` since it injects a non-decodable payload.


## Context and Orientation

You are migrating the `hospital-capacity` service in the `keiro-runtime-jitsurei`
repository at `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`. This is a separate
repository from keiro. The `keiro-pgmq` package this plan depends on lives in the keiro
repository at `/Users/shinzui/Keikaku/bokuno/keiro/keiro-pgmq` and must already be built and
committed (see `docs/plans/55-...` in the keiro repo). Its public API is reproduced in
"Interfaces and Dependencies" below.

Only the `hospital-capacity` service uses PGMQ; the sibling `incident-command` service does
not (it uses Kafka + keiro only) and is out of scope. The relevant code, discovered by
reading the current tree (paths under
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/services/hospital-capacity/src/`):

- `HospitalCapacity/Reservation/WorkQueue.hs` — the module that holds everything:
  - Payload `data ReservationWorkItem` (fields: `reservationId`, `hospitalId`, `commandId`,
    `patientAcuity`, `requiredBedType`, `sourceMessageId`, `expirationDeadline`,
    `divertStatus`, `lifeCriticalOverride`), plus `reservationWorkItemToValue` /
    `reservationWorkItemFromValue` JSON codecs.
  - Queue names: logical `hospital_capacity.reservation_work`, physical
    `hospital_capacity_reservation_work` (dots replaced by hand), DLQ
    `hospital_capacity_reservation_work_dlq`.
  - `enqueueReservationWorkWithTelemetry` — creates the queue + DLQ then `sendMessage`.
  - `reservationWorkAdapterConfig = (defaultConfig reservationWorkQueueName) {
    deadLetterConfig = Just (directDeadLetter reservationWorkDlqName True), maxRetries = 3 }`.
  - `runReservationWorkConsumerOnceWithTelemetry` — builds `pgmqAdapter`, wraps its `source`
    with `Stream.take 1`, runs `runWithMetrics 1 (ProcessorId "reservation-work") adapter
    (processOne ...)`.
  - `processOne` / `processReservationWorkValue` — decode the `Value`, dispatch, map a
    `ReservationWorkFailure` to an `AckDecision` via `reservationWorkFailureAck`.
  - `dispatchReservationWork` — turns an item into a command and runs
    `runReservationCommandDurablyWithTelemetry`.
  - `withHospitalPgmqPool` — acquires a hasql pool; `runPgmqIOWithTelemetry` — runs the
    `Pgmq : Tracing : Error PgmqRuntimeError : IOE` stack with an optional tracer.
- `HospitalCapacity/Integration/ReservationWorkDispatch.hs` — the fan-out call site:
  `traverse (enqueueReservationWorkWithTelemetry tracer pool) newItems` and the pre-enqueue
  idempotency query `reservationWorkPendingOrDecided`.
- `services/hospital-capacity/hospital-capacity.cabal` depends on `pgmq-core`,
  `pgmq-effectful`, `shibuya-core`, `shibuya-kafka-adapter`, `shibuya-pgmq-adapter`. The
  repo's `cabal.project` pins pgmq and shibuya-pgmq-adapter via `file://`
  `source-repository-package` stanzas.
- CLI: `services/hospital-capacity/.../WorkerCli.hs` exposes
  `["reservation-work", "setup" | "enqueue-latest" | "consume", "once"]` subcommands that
  call the functions above.

Confirm these paths and signatures by reading the files before editing; the tree is the
source of truth.

Terms: a **Job** is a `keiro-pgmq` value bundling a queue, a payload codec, and a retry/DLQ
policy. **JobOutcome** is what a handler returns: `Done` (delete), `Retry delay`
(redeliver), `Dead reason` (DLQ). **One-shot drain** means processing up to N currently
available messages then stopping, which is what `runReservationWorkConsumerOnceWithTelemetry`
does today via `Stream.take 1` and which `runJobOnce` provides directly.


## Plan of Work

### Milestone 1 — Pin keiro-pgmq

In the repo's `cabal.project`, add a `source-repository-package` stanza for `keiro-pgmq`
matching the `file://` convention the repo already uses for pgmq/shibuya, pointing at the
keiro repo with `subdir: keiro-pgmq` and the SHA from `docs/plans/55-...`:

```text
source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/bokuno/keiro
  tag: <keiro SHA with keiro-pgmq merged>
  subdir: keiro-pgmq
```

Add `keiro-pgmq` to `hospital-capacity.cabal`'s `build-depends`. Acceptance: from
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`, `cabal build hospital-capacity`
resolves (no service code changed yet).

### Milestone 2 — Declare the job and port the producer

Add the job declaration to `WorkQueue.hs`:

```haskell
reservationWorkJob :: Job ReservationWorkItem
reservationWorkJob = Job
  { jobName   = "reservation-work"
  , jobQueue  = queueRef "hospital_capacity.reservation_work"   -- derives physical + _dlq
  , jobCodec  = aesonJobCodec                                    -- reuse existing JSON codecs
  , jobPolicy = RetryPolicy { maxRetries = 3, defaultRetryDelay = RetryDelay 5, useDeadLetter = True }
  }
```

Note `queueRef "hospital_capacity.reservation_work"` derives exactly the physical name
(`hospital_capacity_reservation_work`) and DLQ (`..._dlq`) the service builds by hand today,
so the on-the-wire queue names are unchanged. If `ReservationWorkItem` already has
`ToJSON`/`FromJSON` instances, `aesonJobCodec` works directly; if it only has the bespoke
`reservationWorkItemToValue`/`reservationWorkItemFromValue` functions, either add the
instances or build a `JobCodec` literally:
`JobCodec reservationWorkItemToValue (first renderFailure . reservationWorkItemFromValue)`
(adapting the error to `Text`). Prefer the literal `JobCodec` to keep the existing,
test-covered codecs.

Rewrite `enqueueReservationWorkWithTelemetry` (and its call site in
`ReservationWorkDispatch.hs`) to use `enqueue reservationWorkJob item` under
`runJobEff`/`runPgmqIOWithTelemetry`. Keep `ensureJobQueue reservationWorkJob` where the old
code called `createQueue` for the queue and DLQ — it does both idempotently. Keep the
pre-enqueue idempotency check (`reservationWorkPendingOrDecided`) exactly as-is; it still
gates which items reach `enqueue`.

Acceptance: `cabal build hospital-capacity`. The `reservation-work setup` and `enqueue-latest`
CLI subcommands still create the queues and enqueue items (run them against a local Postgres
and observe rows appear in `pgmq.q_hospital_capacity_reservation_work`).

### Milestone 3 — Port the consumer and handler

Rewrite the handler to the domain shape, dropping the `Ingested`/`Value` decode and the
`AckDecision` mapping:

```haskell
handleReservationWork :: (ReservationWorkEff es) => Maybe Tracer -> KirokuStore -> ReservationWorkItem -> Eff es JobOutcome
handleReservationWork tracer store item = do
  result <- dispatchReservationWork tracer store item     -- unchanged domain logic
  pure $ case result of
    Left (ReservationWorkStoreFailed _)     -> Retry (RetryDelay 5)
    Left (ReservationWorkCommandRejected e) -> Dead e
    Left (ReservationWorkDecodeFailed e)    -> Dead e      -- defensive; decode now happens in the package
    Right ()                                -> Done
```

Replace `runReservationWorkConsumerOnceWithTelemetry`'s body with `runJobOnce`:

```haskell
runReservationWorkConsumerOnceWithTelemetry tracer store pool =
  runPgmqIOWithTelemetry tracer pool $ do
    ensureJobQueue reservationWorkJob
    runJobOnce 1 reservationWorkJob (handleReservationWork tracer store)
```

`runJobOnce 1` reproduces today's `Stream.take 1` one-shot behavior; pass a larger N to drain
more per invocation if desired (the CLI semantics stay "consume once"). The decode-failure
path that `processReservationWorkValue` handled by hand is now the package's job — an
undecodable message is routed to the DLQ by `wrapHandler` inside `keiro-pgmq`, so you no
longer write that case (the defensive `ReservationWorkDecodeFailed` arm above only fires if
your own `dispatchReservationWork` still surfaces it internally).

Acceptance: `cabal build hospital-capacity`. Run `reservation-work consume once` against a
queue holding a valid item and observe a `TransferReservationCreated` event appended (the
same assertion the service makes today).

### Milestone 4 — Delete dead plumbing; verify parity (including DLQ)

Remove what the package now owns from `WorkQueue.hs`: `reservationWorkAdapterConfig`,
`processOne` / `processReservationWorkValue`, `reservationWorkFailureAck`, and the manual
`pgmqAdapter` + `Stream.take` + `runWithMetrics` wiring. Keep `dispatchReservationWork`,
`reservationWorkItemToValue`/`FromValue`, the `ReservationWorkFailure` type (still used by
`dispatchReservationWork`), `withHospitalPgmqPool`, and `runPgmqIOWithTelemetry` (the last
is the service's own thin wrapper over the same stack `runJobEff` provides — you may keep it
or switch fully to `withJobRuntime`/`runJobEff`; keeping it is fine since the effect stacks
match). If `hospital-capacity` no longer references `shibuya-pgmq-adapter` or
`pgmq-effectful` directly after the cuts, drop them from `build-depends` (keiro-pgmq pulls
them transitively); keep `shibuya-kafka-adapter` (still used for Kafka).

Acceptance: full parity, including the failure paths. The integration scenario the service
already documents in
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei/.../docs/plans/4-connect-bounded-contexts-with-kafka-and-pgmq.md`
must still hold end to end: incident declares a transfer need → router fans out → items
enqueued → consumer appends `TransferReservationCreated` → response published. Additionally
verify the DLQ path: feed a malformed item (the existing
`enqueueMalformedReservationWorkWithTelemetry` test fixture) and confirm, after a consume,
it lands in `pgmq.q_hospital_capacity_reservation_work_dlq` — proving the package's
`maxRetries = 3` + `directDeadLetter` policy reproduces the old behavior.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`.

```bash
# Milestone 1
# (edit cabal.project: add keiro-pgmq file:// source-repository-package pin)
# (edit services/hospital-capacity/hospital-capacity.cabal: add keiro-pgmq to build-depends)
cabal build hospital-capacity
```

```bash
# Milestones 2-4: after each set of edits
cabal build hospital-capacity
cabal test hospital-capacity     # or the suite the service defines

# Exercise the CLI end to end against a local Postgres
cabal run hospital-capacity -- reservation-work setup
cabal run hospital-capacity -- reservation-work enqueue-latest
cabal run hospital-capacity -- reservation-work consume once
```

Commit after each milestone. Every commit (in the keiro-runtime-jitsurei repo) carries all
three trailers; the MasterPlan/ExecPlan paths are relative to the keiro repo:

```text
Port hospital-capacity reservation work to keiro-pgmq

MasterPlan: docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md
ExecPlan: docs/plans/57-migrate-hospital-capacity-reservation-work-onto-keiro-pgmq.md
Intention: intention_01kthhpasxesx8hp84264cjhpx
```


## Validation and Acceptance

Acceptance is behavioral parity with today on both the happy path and the DLQ path:

- `cabal build hospital-capacity` succeeds.
- The service's test suite passes.
- Happy path: `reservation-work setup` → `enqueue-latest` → `consume once` results in a
  `TransferReservationCreated` event appended for a valid item.
- Retry path: an item whose dispatch hits a store failure stays on the queue and becomes
  visible again after ~5s (the `Retry (RetryDelay 5)` mapping).
- DLQ path: a malformed item (existing `enqueueMalformedReservationWorkWithTelemetry`
  fixture), after a consume, appears in
  `pgmq.q_hospital_capacity_reservation_work_dlq`.
- Grep proves cleanup: `rg 'pgmqAdapter|reservationWorkAdapterConfig|AckDecision|reservationWorkFailureAck'
  services/hospital-capacity` returns no matches in `WorkQueue.hs`.


## Idempotence and Recovery

`ensureJobQueue` and PGMQ `createQueue` are idempotent — safe to call at every `setup`/
`consume` invocation. `runJobOnce` is a bounded drain (processes up to N then stops), so
re-running it is safe; messages a handler returns `Retry` for simply remain for the next
run. The migration touches a single module and a single call site, so reverting is
straightforward: restore `WorkQueue.hs`'s manual consumer/handler and the producer's
`sendMessage` to return to the old path. The pre-enqueue idempotency check
(`reservationWorkPendingOrDecided`) is preserved, so duplicate fan-out enqueues remain
suppressed throughout.


## Interfaces and Dependencies

This plan depends on the `keiro-pgmq` package from
`docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md`. The
public API you program against:

```haskell
-- Keiro.PGMQ.Runtime
data QueueRef
queueRef       :: Text -> QueueRef
data JobRuntime
withJobRuntime :: Text -> Maybe OTel.Tracer -> (JobRuntime -> IO a) -> IO a
runJobEff      :: JobRuntime -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] a -> IO (Either PgmqRuntimeError a)

-- Keiro.PGMQ.Codec
data JobCodec p = JobCodec { encodeJob :: p -> Value, decodeJob :: Value -> Either Text p }
aesonJobCodec  :: (ToJSON p, FromJSON p) => JobCodec p

-- Keiro.PGMQ.Job
data JobOutcome = Done | Retry !RetryDelay | Dead !Text          -- RetryDelay is RE-EXPORTED from Keiro.PGMQ
data RetryPolicy = RetryPolicy { maxRetries :: !Int64, defaultRetryDelay :: !RetryDelay, useDeadLetter :: !Bool }
data Job p = Job { jobName :: !Text, jobQueue :: !QueueRef, jobCodec :: !(JobCodec p), jobPolicy :: !RetryPolicy }
enqueue        :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es Pgmq.MessageId
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
runJobOnce     :: (Pgmq :> es, IOE :> es, Tracing :> es) => Int -> Job p -> (p -> Eff es JobOutcome) -> Eff es ()
```

Import from `Keiro.PGMQ` (umbrella) or the submodules. **`RetryDelay` is re-exported by
`Keiro.PGMQ` (EP-1 outcome, 2026-06-07) — import it from there, not from `Shibuya.Core.Ack`.**
The service's existing `runPgmqIOWithTelemetry` already establishes the
`Pgmq : Tracing : Error PgmqRuntimeError : IOE` stack that
`enqueue`/`ensureJobQueue`/`runJobOnce` require, so they slot in without re-plumbing. EP-1
confirmed `runJobOnce` is implemented exactly as this service's
`runReservationWorkConsumerOnceWithTelemetry` does its one-shot drain
(`Shibuya.Runner.Supervised.runWithMetrics` over `Stream.take n`), so the swap is mechanical.

If `docs/plans/55-...` changed any of these signatures during its implementation, the
MasterPlan's Integration Points section is the authority — reconcile against it before
starting, and update this section to match.
