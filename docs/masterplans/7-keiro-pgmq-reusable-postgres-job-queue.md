---
id: 7
slug: keiro-pgmq-reusable-postgres-job-queue
title: "keiro-pgmq reusable Postgres job queue"
kind: master-plan
created_at: 2026-06-07T17:25:15Z
intention: "intention_01kthhpasxesx8hp84264cjhpx"
---

# keiro-pgmq reusable Postgres job queue

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Today, every keiro application that needs a background job queue hand-rolls the same
integration against `pgmq-hs` (a Haskell client for PGMQ, the PostgreSQL-native message
queue) and `shibuya-pgmq-adapter` (the bridge that lets shibuya, a Broadway-style queue
worker framework, consume a PGMQ queue). Two real applications already prove this:
`rei` (four queues for git sync, reminders, reflections, and agent scheduling) and the
`hospital-capacity` service inside `keiro-runtime-jitsurei` (one reservation-work queue
with a dead-letter queue). Both arrived independently at byte-for-byte the same skeleton:
derive a PGMQ-legal queue name, construct a `PgmqAdapterConfig`, write a producer that
wraps `sendMessage`, write a handler of type `Ingested es Value -> Eff es AckDecision`
that decodes JSON and maps domain failures to ack decisions, and wire an effect stack of
`Pgmq : Tracing : Error : IOE`. None of this is shared. None of it uses keiro's versioned
`Keiro.Codec`, so payload-shape changes are unversioned breaks.

After this initiative, keiro ships a new library package, `keiro-pgmq`, that absorbs that
skeleton behind a typed `Job` abstraction — the background-work analogue of keiro's
existing `Keiro.EventStream`. An application declares a `Job p` value bundling a queue,
a payload codec, and a retry/dead-letter policy, then writes a domain handler of type
`p -> Eff es JobOutcome` where `JobOutcome` is `Done | Retry delay | Dead reason`. The
handler never touches shibuya's `Ingested`/`AckDecision` or PGMQ's wire types. The package
provides `enqueue` (producer), `ensureJobQueue` (idempotent queue + DLQ creation),
`jobProcessor` (build a shibuya processor from a `Job` plus a handler), and two run shapes:
`runJobWorkers` (continuous, multi-processor — the `rei` cadence) and `runJobOnce`
(one-shot drain — the `hospital-capacity` cadence). The package is split into two layers:
`Keiro.PGMQ.Runtime` (transport-agnostic plumbing — queue-name derivation, the
`Pgmq : Tracing : Error : IOE` runner, pool/tracer lifecycle) and `Keiro.PGMQ.Job` (the
typed-Job ergonomics built on top of layer 1).

The initiative then migrates both proving grounds onto the package — `rei` and
`hospital-capacity` — which both validates the abstraction against two genuinely different
cadences and deletes the duplicated boilerplate from each. Success is observable: both
applications keep their existing background-work behavior (a verifiable end-to-end
scenario each), but their queue modules shrink to `Job` declarations plus domain handlers,
and both depend on `keiro-pgmq` instead of wiring `pgmq-effectful` + `shibuya-pgmq-adapter`
by hand.

In scope: the `keiro-pgmq` package (case A — transient background jobs that are **not**
domain events), the two consumer migrations, and a recorded-but-deferred design for case B.

Explicitly excluded (case B, deferred): using PGMQ as a delivery transport for domain
**integration events** as a Kafka alternative (leveraging PGMQ topics/fan-out under
`Keiro.Inbox` / `Keiro.Outbox`). Case B is captured as a deferred child plan
(`docs/plans/58-deferred-pgmq-as-transport-for-integration-events-case-b.md`) so the design
is not lost, and the package's two-layer split is engineered so case B can later reuse
`Keiro.PGMQ.Runtime` without disturbing the `Job` layer. Case B is not built in this
initiative.


## Decomposition Strategy

The work was decomposed by functional concern into four child plans. The decisive split is
between **producing the reusable artifact** (one plan) and **proving it against real
consumers** (two plans), with a fourth plan that records deferred design so it is not lost.

The package itself (EP-1) is the spine: a self-contained library deliverable validated by
its own integration test against an ephemeral Postgres with PGMQ installed. It is the only
plan with no dependencies and must land first because nothing else compiles without its
public API.

The two migrations (EP-2 for `rei`, EP-3 for `hospital-capacity`) are deliberately separate
plans rather than one, for three reasons. First, they live in **different repositories**
(`/Users/shinzui/Keikaku/bokuno/rei-project/rei` and
`/Users/shinzui/Keikaku/bokuno/keiro-runtime-jitsurei`), with independent build and test
cycles. Second, they exercise **different cadences** of the same API — `rei` runs many
queues continuously under one supervisor with enqueues driven by periodic `pg_cron`
sweeps, whereas `hospital-capacity` runs a single queue one-shot with enqueues driven by a
keiro `Router` fan-out and a dead-letter queue. Keeping them separate means each migration
independently verifies a different slice of the package's surface, which is exactly the
validation we want. Third, they can proceed in **parallel** once EP-1 lands, by two
different contributors or sessions, with no code coupling between them.

EP-4 (case B) is a deferred design-capture plan. It is not implemented in this initiative;
it exists to preserve the future-enhancement design and to pin down the integration point
that keeps it cheap later (reuse of `Keiro.PGMQ.Runtime`, not the `Job` layer).

Alternatives considered. **A single ExecPlan** building the package and migrating one
consumer inline was rejected because three repositories and cross-repo version-pin
propagation make coordination — not code — the hard problem, which is precisely what a
MasterPlan is for. **Folding both migrations into one plan** was rejected because they are
in separate repos with separate verification and can run in parallel; merging them would
serialize unrelated work and violate the independent-verifiability principle. **Putting
`keiro-pgmq` inside `keiro-core`** was rejected to keep `keiro-core` dependency-light;
the package lives as a separate library that depends on `pgmq-*` and `shibuya-pgmq-adapter`,
mirroring how shibuya keeps its adapters (`shibuya-pgmq-adapter`, `shibuya-kafka-adapter`)
out of `shibuya-core`, and how keiro deliberately keeps `hw-kafka-client` out of the
framework by shipping pure transport codecs.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Build the keiro-pgmq package with typed Job and Runtime layers | docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md | None | None | Complete |
| 2 | Migrate rei background queues onto keiro-pgmq | docs/plans/56-migrate-rei-background-queues-onto-keiro-pgmq.md | EP-1 | None | Complete |
| 3 | Migrate hospital-capacity reservation work onto keiro-pgmq | docs/plans/57-migrate-hospital-capacity-reservation-work-onto-keiro-pgmq.md | EP-1 | None | Not Started |
| 4 | Deferred pgmq-as-transport for integration events (case B) | docs/plans/58-deferred-pgmq-as-transport-for-integration-events-case-b.md | None | EP-1 | Deferred (Not Started) |

Status values: Not Started, In Progress, Complete, Cancelled, Deferred.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1).


## Dependency Graph

EP-1 has no dependencies and must complete first: it defines the entire public API
(`Job`, `JobOutcome`, `JobCodec`, `enqueue`, `ensureJobQueue`, `jobProcessor`,
`runJobWorkers`, `runJobOnce`, and the `Keiro.PGMQ.Runtime` layer) that EP-2 and EP-3
consume. Both migrations have a **hard** dependency on EP-1 because their migrated code
will not compile without `keiro-pgmq`'s modules and types.

EP-2 and EP-3 are mutually independent and may proceed in parallel once EP-1 is Complete
and the `keiro-pgmq` source is reachable from each consumer's build (see Integration
Points — the cross-repo pin). Neither migration shares code with the other; they share only
the package they both depend on.

EP-4 has a **soft / integration** dependency on EP-1: it is not blocked by EP-1 and is not
scheduled in this initiative, but when it is eventually picked up it must build on
`Keiro.PGMQ.Runtime` (layer 1) rather than the `Job` layer. EP-1 is responsible for keeping
that layer cleanly separable so EP-4 stays cheap.


## Integration Points

**1. The `keiro-pgmq` public API (shared by EP-1, EP-2, EP-3).** EP-1 defines it; EP-2 and
EP-3 consume it. The contract both migrations rely on:

```haskell
-- Keiro.PGMQ.Job
data JobOutcome = Done | Retry !RetryDelay | Dead !Text

data RetryPolicy = RetryPolicy
  { maxRetries        :: !Int64
  , defaultRetryDelay :: !RetryDelay
  , useDeadLetter     :: !Bool
  }

data Job p = Job
  { jobName   :: !Text
  , jobQueue  :: !QueueRef          -- from Keiro.PGMQ.Runtime
  , jobCodec  :: !(JobCodec p)      -- from Keiro.PGMQ.Codec
  , jobPolicy :: !RetryPolicy
  }

enqueue        :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es Pgmq.MessageId
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
jobProcessor   :: (Pgmq :> es, IOE :> es, Tracing :> es)
               => Job p -> (p -> Eff es JobOutcome)
               -> Eff es (ProcessorId, QueueProcessor es)
runJobWorkers  :: (Pgmq :> es, IOE :> es, Tracing :> es)
               => SupervisionStrategy -> Int
               -> [Eff es (ProcessorId, QueueProcessor es)]
               -> Eff es (Either AppError (AppHandle es))
runJobOnce     :: (Pgmq :> es, IOE :> es, Tracing :> es)
               => Int -> Job p -> (p -> Eff es JobOutcome) -> Eff es ()
```

If EP-1 changes any of these signatures during implementation, it must update this section
and both EP-2 and EP-3's "Interfaces and Dependencies" sections to match before those plans
begin. EP-2 and EP-3 must reference these signatures only through `keiro-pgmq`, never by
re-deriving shibuya/pgmq types directly.

**EP-1 outcome (2026-06-07): the listed signatures all hold as published, with two
refinements (see Surprises & Discoveries).** `RetryDelay` is re-exported from `Keiro.PGMQ`,
so import it from there, not `Shibuya.Core.Ack`. `enqueueWithDelay :: (Pgmq :> es, IOE :> es)
=> Job p -> Int32 -> p -> Eff es Pgmq.MessageId` takes PGMQ's `Delay` (= `Int32`).

**2. The two-layer module split (shared by EP-1 and EP-4).** EP-1 owns the boundary:
`Keiro.PGMQ.Runtime` holds transport-agnostic plumbing (queue-name derivation via
`QueueRef`, the `Pgmq : Tracing : Error PgmqRuntimeError : IOE` runner, pool + tracer
lifecycle); `Keiro.PGMQ.Job` holds the case-A Job ergonomics built on top. EP-4 (case B)
must, when implemented, build `Keiro.Inbox.Pgmq` / `Keiro.Outbox.Pgmq` transport codecs on
`Keiro.PGMQ.Runtime` and must **not** depend on `Keiro.PGMQ.Job`. EP-1 must not leak
Job-specific concerns into the Runtime layer.

**3. Cross-repo version pin (shared by EP-2 and EP-3; pure coordination).** `keiro-pgmq`
lives in the keiro repository (`/Users/shinzui/Keikaku/bokuno/keiro`). `rei` and
`keiro-runtime-jitsurei` are separate repositories that already pin `pgmq-*` and
`shibuya-pgmq-adapter` via `source-repository-package` stanzas in their `cabal.project`
files (jitsurei uses `file://` local pins; rei uses git pins — each migration must follow
its own repo's existing convention). EP-2 and EP-3 each add a `source-repository-package`
pin for `keiro-pgmq` subdir `keiro-pgmq` at the keiro SHA produced by EP-1. Bumping that pin
is the integration step between EP-1 completion and each migration's start. The plan-doc
commits live in the keiro repo; the actual migration code commits live in each consumer's
repo — both carry the `MasterPlan:` trailer (the path is relative to the keiro repo).


## Progress

Track milestone-level progress across all child plans.

- [x] EP-1: Scaffold `keiro-pgmq` package (cabal, mori.dhall, cabal.project, empty modules build) (2026-06-07)
- [x] EP-1: `Keiro.PGMQ.Runtime` — `QueueRef` name derivation + effect-stack runner + pool/tracer lifecycle (2026-06-07)
- [x] EP-1: `Keiro.PGMQ.Codec` — `JobCodec`, `aesonJobCodec`, versioned `keiroJobCodec` (2026-06-07)
- [x] EP-1: `Keiro.PGMQ.Job` — `Job`/`JobOutcome`/`RetryPolicy`, `enqueue`, `ensureJobQueue`, `jobProcessor`, `runJobWorkers`, `runJobOnce` (2026-06-07)
- [x] EP-1: Integration test — enqueue → consume → Done/Retry/Dead against ephemeral Postgres with PGMQ installed (2026-06-07 — `cabal test keiro-pgmq`: 5 examples, 0 failures)
- [x] EP-2: Pin `keiro-pgmq` in rei; port one queue (git sync) as a template (2026-06-07 — rei commits `7516fe61`, `c4c8c06c`)
- [x] EP-2: Port remaining rei queues (reminders, reflections, agent work); delete hand-rolled boilerplate (2026-06-07 — rei commits `88b366ce`, `6f179474`)
- [x] EP-2: End-to-end verification of rei background-work parity (2026-06-07 — full rei-core suite, 932 tests, passes; git-sync handler integration test green)
- [ ] EP-3: Pin `keiro-pgmq` in keiro-runtime-jitsurei; port hospital-capacity reservation work + DLQ
- [ ] EP-3: End-to-end verification of hospital-capacity reservation-work parity
- [ ] EP-4: (Deferred) design captured; not implemented this initiative


## Surprises & Discoveries

- 2026-06-07 (EP-1) — **The `keiro-pgmq` public API is final and matches Integration Point 1,
  with two refinements EP-2 and EP-3 must adopt.** (1) `RetryDelay` is now re-exported from
  `Keiro.PGMQ` (the package), because `JobOutcome`'s `Retry !RetryDelay` constructor is
  public — consumers should import `RetryDelay` from `Keiro.PGMQ`, **not** from
  `Shibuya.Core.Ack`. (2) `enqueueWithDelay`'s delay argument is `Int32` (PGMQ's
  `type Delay = Int32`), not a named `Pgmq.Delay`. All other signatures in Integration
  Point 1 hold exactly as published. The producer signatures retain their `IOE` constraint
  as published.

- 2026-06-07 (EP-1) — **Affects Integration Point 3 (cross-repo pin) for EP-2/EP-3.** Inside
  the keiro repo, the pgmq/shibuya family is NOT pinned via `source-repository-package`; it
  resolves from a private cabal mirror served under the `hackage.haskell.org` repository
  name (versions in play: pgmq-* 0.3.0.0, shibuya-* 0.7.0.0). EP-1 added exactly one pin to
  keiro's `cabal.project`: the patched `github.com/shinzui/hasql-migration` fork (tag
  `4aaff6c…`), required only by the *test* build (`pgmq-migration` → `hasql-migration`;
  Hackage's 0.3.1 will not build against hasql 1.10). EP-2/EP-3 should expect that their
  own repos already pin the pgmq/shibuya family their own way (per Integration Point 3) and
  add a `keiro-pgmq` pin at the keiro SHA produced here. When `keiro-pgmq`'s *test* is built
  inside a consumer repo (rarely needed — consumers depend on the library, not its test),
  that repo would also need the `hasql-migration` fork pin; depending on the library alone
  does not pull it in.

- 2026-06-07 (EP-2) — **The cross-repo pin required a shibuya 0.6→0.7 upgrade first; EP-3
  should expect the same precondition.** rei pinned `shibuya-core`/`shibuya-pgmq-adapter` at
  `^>=0.6` (< 0.7) while `keiro-pgmq` requires `shibuya-* >=0.7 && <0.8`. Adding the
  `keiro-pgmq` pin was therefore blocked until rei's whole eventing stack was upgraded to
  shibuya 0.7 (also pulling `shibuya-kiroku-adapter` 0.3 from the kiroku git pin, since
  Hackage only carries 0.2). Integration Point 3 said "expect your repo already pins the
  pgmq/shibuya family their own way" — the sharper lesson is that the family must be at **0.7**,
  not merely pinned. EP-3 (keiro-runtime-jitsurei) must be on shibuya 0.7 before pinning
  keiro-pgmq.

- 2026-06-07 (EP-2) — **rei's pre-migration queues had NO dead-letter queue (shibuya
  `defaultConfig`: `deadLetterConfig = Nothing`, `maxRetries = 3`).** Behaviour-preserving
  parity therefore used a custom `reiQueuePolicy` (3 retries, `useDeadLetter = False`), not
  keiro-pgmq's `defaultRetryPolicy` (5 retries + DLQ). This is a per-consumer choice:
  **EP-3 (hospital-capacity) genuinely uses a DLQ**, so it will use a DLQ-enabled policy and
  the `runJobOnce` one-shot cadence, exercising package surface that EP-2 did not.

- 2026-06-07 (EP-2) — **The migration's payoff is on the consumer side, not the producer
  side.** rei's real git-sync and agent-task enqueues are transactional raw-SQL `pgmq.send`
  projections (exactly-once, committed with a dedup-claim insert), which keiro-pgmq's
  `enqueue` (a separate `Pgmq`-effect transaction) cannot and should not replace. The shibuya
  `Ingested`/`AckDecision` coupling lived in the handlers + runner, and that is what
  keiro-pgmq absorbed. The periodic-check producers (which use the `Pgmq` effect) did move to
  `enqueue`. EP-3 reviewers: don't assume every producer becomes `enqueue`.

- 2026-06-07 (EP-1) — **`runJobOnce` cadence confirmed against the real reference.** The
  one-shot drain is implemented with `Shibuya.Runner.Supervised.runWithMetrics` over
  `Streamly.Data.Stream.take n adapter.source`, mirroring `hospital-capacity`'s
  `runReservationWorkConsumerOnceWithTelemetry`. EP-3's migration is therefore a near
  mechanical swap onto `runJobOnce`.


## Decision Log

- Decision: Decompose into four child plans — one package, two consumer migrations, one
  deferred design-capture.
  Rationale: The reusable artifact and its two real-consumer validations are distinct
  functional concerns across three repositories; the migrations exercise two different
  cadences of the same API and can run in parallel. A deferred plan preserves case B's
  design without scheduling it.
  Date: 2026-06-07

- Decision: Ship `keiro-pgmq` as a separate library package, not inside `keiro-core`.
  Rationale: Keep `keiro-core` dependency-light. Mirrors shibuya keeping adapters out of
  `shibuya-core` and keiro keeping `hw-kafka-client` out of the framework. The package
  depends on `pgmq-core`, `pgmq-effectful`, and `shibuya-pgmq-adapter`.
  Date: 2026-06-07

- Decision: Two-layer split — `Keiro.PGMQ.Runtime` (transport-agnostic) and
  `Keiro.PGMQ.Job` (case-A ergonomics).
  Rationale: Preserves case B (pgmq-as-transport) as a cheap future enhancement that reuses
  the Runtime layer without retrofitting the Job layer. Recorded as Integration Point 2.
  Date: 2026-06-07

- Decision: Treat case A (transient background jobs that are NOT domain events) as the only
  thing built now; record case B as deferred.
  Rationale: Both proving-ground consumers use the queue strictly for transient,
  non-domain work; the immediate need is case A. Case B (Kafka-free integration-event
  transport via PGMQ fan-out) is a real future option teams may want and must not be lost.
  Date: 2026-06-07


## Outcomes & Retrospective

(To be filled during and after implementation.)
</content>
</invoke>
