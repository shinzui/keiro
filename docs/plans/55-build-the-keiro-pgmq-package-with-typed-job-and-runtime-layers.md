---
id: 55
slug: build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers
title: "Build the keiro-pgmq package with typed Job and Runtime layers"
kind: exec-plan
created_at: 2026-06-07T17:25:21Z
intention: "intention_01kthhpasxesx8hp84264cjhpx"
master_plan: "docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md"
---

# Build the keiro-pgmq package with typed Job and Runtime layers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan creates a brand-new Haskell library package, `keiro-pgmq`, inside the keiro
repository. The package gives keiro applications a ready-made, typed background-job queue
on top of PostgreSQL so they stop hand-rolling the same plumbing.

Background, in plain terms. **PGMQ** is a message queue that lives inside PostgreSQL: you
create a named queue, push JSON messages onto it, and workers read messages, do work, then
delete (acknowledge) or retry them. **pgmq-hs** is the Haskell client for PGMQ; its
`pgmq-effectful` package exposes queue operations as an `effectful` effect named `Pgmq`
(`effectful` is a Haskell effect-system library; an "effect" is a capability your code can
request, like "I can talk to PGMQ"). **shibuya** is a worker framework (Broadway-style):
you give it an "adapter" (a source of messages) and a "handler" (what to do with each
message), and it runs a supervised polling loop. **shibuya-pgmq-adapter** is the bridge
that turns a PGMQ queue into a shibuya adapter, translating a handler's decision
(`AckOk`/`AckRetry`/`AckDeadLetter`) into PGMQ operations (delete / extend visibility /
move to a dead-letter queue). A **dead-letter queue (DLQ)** is a second queue where
messages that fail too many times are parked so they stop blocking the main queue.

Two real apps already use this stack and both wrote the same boilerplate by hand: derive a
PGMQ-legal queue name, build a config, write a producer wrapping `sendMessage`, write a
handler of type `Ingested es Value -> Eff es AckDecision` that decodes JSON and maps errors
to acks, and assemble an effect stack `Pgmq : Tracing : Error : IOE`. Neither uses keiro's
versioned codec, so changing a payload shape is an unversioned break.

After this plan, an application instead writes a declarative `Job` value and a plain domain
handler. Concretely, after implementation a developer can:

- Declare `gitSyncJob :: Job NoteGitSyncPayload` bundling a queue, a payload codec, and a
  retry/DLQ policy.
- Call `enqueue gitSyncJob payload` to put work on the queue.
- Write a handler `handle :: NoteGitSyncPayload -> Eff es JobOutcome` returning
  `Done`, `Retry delay`, or `Dead reason` — never touching shibuya or PGMQ wire types.
- Run it continuously with `runJobWorkers` or drain once with `runJobOnce`.

You can see it working by running this package's own integration test, which spins up a
throwaway PostgreSQL, installs PGMQ, enqueues messages through `enqueue`, drains them with
`runJobOnce`, and asserts that a `Done` handler deletes the message, a `Retry` handler
leaves it for redelivery, and a `Dead` handler routes it to the DLQ.


## Progress

- [x] Milestone 1: Scaffold the `keiro-pgmq` package so an empty library builds. (2026-06-07 — `cabal build keiro-pgmq` compiles the 4 stub modules; deps resolve from the private registry, no `source-repository-package` pins.)
- [x] Milestone 2: `Keiro.PGMQ.Runtime` — `QueueRef` name derivation + effect-stack runner. (2026-06-07 — compiles; `runJobEff` mirrors jitsurei's `runErrorNoCallStack`/`runTracing`/`runPgmqTraced` ordering. `withJobRuntime` acquires/releases a hasql pool. Tracer threaded via shibuya's re-exported `Tracer`. Used parenthesized `$` lambda instead of `BlockArguments`.)
- [x] Milestone 3: `Keiro.PGMQ.Codec` — `JobCodec`, `aesonJobCodec`, versioned `keiroJobCodec`. (2026-06-07 — compiles; `keiroJobCodec` wraps `{v,data}` and replays `Keiro.Codec.migrateToCurrent`.)
- [x] Milestone 4: `Keiro.PGMQ.Job` — types, `enqueue`, `ensureJobQueue`, `jobProcessor`, `runJobWorkers`, `runJobOnce`, umbrella re-export. (2026-06-07 — full public API compiles. `runJobOnce` uses `Shibuya.Runner.Supervised.runWithMetrics` over `Stream.take n`. `enqueueWithDelay` takes `Int32` (PGMQ `Delay = Int32`, not exported from `Pgmq.Types`). Kept the published `IOE` constraint on producers via a localized `-Wno-redundant-constraints`.)
- [x] Milestone 5: Integration test proving enqueue → consume → Done/Retry/Dead. (2026-06-07 — `cabal test keiro-pgmq` → 5 examples, 0 failures against an ephemeral Postgres with PGMQ installed via `pgmq-migration`. Required pinning the patched `shinzui/hasql-migration` fork in `cabal.project` because Hackage `hasql-migration 0.3.1` does not build against hasql 1.10; only the test build pulls it in.)


## Surprises & Discoveries

- 2026-06-07 — **No `source-repository-package` pins needed for pgmq/shibuya.** The plan
  (Milestone 1, Concrete Steps) said to add `source-repository-package` git pins for the
  pgmq/shibuya family to `cabal.project`. In reality the keiro build resolves these from a
  private cabal package mirror served under the `hackage.haskell.org` repository name (the
  active cabal config is `~/.config/cabal/config -> /run/agenix/cabal_config`). The on-disk
  index `~/.cabal/packages/hackage.haskell.org/` already contains `pgmq-core`,
  `pgmq-effectful`, `pgmq-migration`, `shibuya-core`, and `shibuya-pgmq-adapter`. This is
  how the existing `keiro` package already gets `shibuya-core 0.7.0.0` (verified in
  `dist-newstyle/cache/plan.json`: `shibuya-core 0.7.0.0 src=repo-tar`). So `keiro-pgmq`
  only needs `build-depends` lines plus the `packages:` entry — no pins. Recorded as a
  Decision below.

- 2026-06-07 — **Registry versions:** pgmq-core/effectful/migration `0.3.0.0`,
  shibuya-core/shibuya-pgmq-adapter `0.7.0.0` (plan text said `>=0.5`; the repo unifies on
  0.7), ephemeral-pg `0.2.1.0`, hasql `1.10.3.2`, hasql-pool `1.4.2`, hspec `2.11.17`.

- 2026-06-07 — **API deltas from the plan's reproduced signatures, confirmed against
  source:** `Pgmq.Delay` is a `type Delay = Int32` alias (not a newtype). `pgmq`'s
  `MessageId` (`Int64`) name-clashes with shibuya-core's `MessageId` (`Text`) — must import
  pgmq qualified. The one-shot drain in the `hospital-capacity` reference is
  `Shibuya.Runner.Supervised.runWithMetrics :: (IOE :> es, Tracing :> es) => Natural ->
  ProcessorId -> Adapter es msg -> Handler es msg -> Eff es SupervisedProcessor` driven by
  `Streamly.Data.Stream.take n adapter.source` — not a hand-rolled fold. The Error runner is
  `runErrorNoCallStack @PgmqRuntimeError` from `Effectful.Error.Static`. `pgmq-effectful`'s
  `dropQueue` returns `Bool` (not `()`). `queueMetrics :: QueueName -> Eff es QueueMetrics`
  with field `queueLength :: Int64` is the cleanest read-back for test assertions.

- 2026-06-07 — **`pgmq-migration` drags a broken `hasql-migration` into the test build.**
  `pgmq-migration` depends on `hasql-migration ^>=0.3.1`, but Hackage's `hasql-migration
  0.3.1` does not compile against the hasql 1.10 ecosystem this repo uses — it uses
  `Statement` as a term-level constructor, which fails with
  `Illegal term-level use of the type constructor 'Statement'`. `pgmq-hs`'s own
  `cabal.project` works around this by pinning a patched fork
  (`github.com/shinzui/hasql-migration` tag `4aaff6c…`, "hasql 1.10 ecosystem"). EP-1 adds
  the same `source-repository-package` pin to keiro's `cabal.project`. This is the *only*
  pin EP-1 adds, and it affects the test build only (the library does not depend on
  `pgmq-migration`). Adding it also nudged the solver toward an inconsistent
  shibuya-core 0.6/0.7 plan, fixed by bounding the test stanza to
  `shibuya-core >=0.7 && <0.8`.

- 2026-06-07 — **`RetryDelay` is now re-exported from `Keiro.PGMQ.Job`.** `JobOutcome`'s
  `Retry !RetryDelay` constructor is public, so callers need `RetryDelay` to build a retry
  outcome. Rather than force every consumer (and the test) to reach into
  `Shibuya.Core.Ack`, the `Job` module re-exports `RetryDelay (..)`. EP-2/EP-3 should use
  `Keiro.PGMQ`'s `RetryDelay`, not shibuya's directly.


## Decision Log

- Decision: Package name `keiro-pgmq`; module root `Keiro.PGMQ.*` (Runtime, Codec, Job,
  plus umbrella `Keiro.PGMQ`).
  Rationale: Matches keiro's package/module conventions; the `.PGMQ.` namespace keeps the
  transport explicit and leaves room for future `Keiro.PGMQ.Inbox` / `Keiro.PGMQ.Outbox`
  (case B) under the same root.
  Date: 2026-06-07

- Decision: Default payload codec is `aesonJobCodec` (raw `ToJSON`/`FromJSON`); a separate
  `keiroJobCodec` bridges keiro's versioned `Keiro.Codec` by wrapping payloads in a
  `{ "v": <version>, "data": <payload> }` envelope and running upcasters on decode.
  Rationale: `aesonJobCodec` is a drop-in match for what both consumers do today (so
  migration is mechanical); `keiroJobCodec` is the opt-in upgrade to versioned payloads.
  Date: 2026-06-07

- Decision: Provide two run shapes — `runJobWorkers` (continuous, multi-processor) and
  `runJobOnce` (one-shot drain of up to N messages).
  Rationale: `rei` runs many queues continuously under one supervisor; `hospital-capacity`
  drains a single queue one-shot via `Stream.take 1`. Both cadences must be first-class.
  Date: 2026-06-07

- Decision: Resolve `pgmq-*` and `shibuya-*` from the private cabal package mirror via
  plain `build-depends`, NOT via `source-repository-package` pins.
  Rationale: keiro's build already resolves `shibuya-core 0.7.0.0` as a `repo-tar` from the
  mirror served under `hackage.haskell.org` (config `~/.config/cabal/config ->
  /run/agenix/cabal_config`); the mirror also carries `pgmq-core/effectful/migration` and
  `shibuya-pgmq-adapter`. Adding git pins would be redundant and could fight the solver.
  See the first Surprises entry. (This is an EP-1-local choice. The cross-repo pin described
  in the MasterPlan's Integration Point 3 still governs how the *consumer* repos —
  `rei`, `keiro-runtime-jitsurei` — reach `keiro-pgmq`; that is EP-2/EP-3's concern.)
  Date: 2026-06-07

- Decision: Re-export `RetryDelay (..)` from `Keiro.PGMQ.Job` (and thus `Keiro.PGMQ`).
  Rationale: `JobOutcome`'s `Retry !RetryDelay` is public, so callers must be able to name
  and construct a `RetryDelay`. Re-exporting it keeps consumers from importing
  `Shibuya.Core.Ack` directly. Recorded in Surprises & Discoveries.
  Date: 2026-06-07

- Decision: Use `Int32` (PGMQ's `Delay`) for `enqueueWithDelay`'s delay argument instead of
  a named `Pgmq.Delay`.
  Rationale: `Delay` is a `type Delay = Int32` alias and is not exported from `Pgmq.Types`,
  so naming it would require importing it from somewhere awkward; `Int32` is the same type
  and self-documenting with a doc comment. The published-contract producer signatures keep
  the `IOE` constraint (suppressing the otherwise-correct redundant-constraint warning
  locally) so EP-2/EP-3 see the exact signatures the MasterPlan pins.
  Date: 2026-06-07


## Outcomes & Retrospective

2026-06-07 — **EP-1 complete.** The `keiro-pgmq` library package exists in the keiro repo
and its five-scenario integration test passes (`cabal test keiro-pgmq` → 5 examples, 0
failures) against a throwaway PostgreSQL with PGMQ installed. The full public API
type-checks and behaves: an enqueued message a handler marks `Done` is deleted, one marked
`Retry` stays on the queue, and one marked `Dead` — or one whose payload the codec rejects
— is routed to the dead-letter queue, all read back through `pgmq-effectful`'s
`queueMetrics`. The two layers are cleanly separated: `Keiro.PGMQ.Runtime` (queue-name
derivation + the `Pgmq : Tracing : Error : IOE` runner + pool/tracer lifecycle) carries no
Job-specific concerns, so EP-4 (case B) can later build `Keiro.PGMQ.Inbox`/`.Outbox` on it
without touching `Keiro.PGMQ.Job`.

What landed: `Keiro.PGMQ.Runtime` (`QueueRef`/`queueRef`, `JobRuntime`, `withJobRuntime`,
`runJobEff`), `Keiro.PGMQ.Codec` (`JobCodec`, `aesonJobCodec`, `keiroJobCodec`),
`Keiro.PGMQ.Job` (`JobOutcome`, `RetryDelay` re-export, `RetryPolicy`, `defaultRetryPolicy`,
`Job`, `enqueue`, `enqueueWithDelay`, `ensureJobQueue`, `jobProcessor`, `runJobWorkers`,
`runJobOnce`), and the `Keiro.PGMQ` umbrella.

Deltas from the plan as written, all recorded above: (1) no `source-repository-package` pins
for the pgmq/shibuya family were needed — they resolve from the private cabal mirror; (2)
the only pin added was the patched `shinzui/hasql-migration` fork, required by
`pgmq-migration` in the *test* build; (3) `runJobOnce` is implemented with
`Shibuya.Runner.Supervised.runWithMetrics` over `Stream.take n` (mirroring the
`hospital-capacity` reference) rather than a hand-rolled streamly fold; (4) `RetryDelay` is
re-exported from the package; (5) `enqueueWithDelay` takes `Int32`.

Interface note for EP-2/EP-3: the signatures in this plan's "What this milestone set must
yield" and the MasterPlan's Integration Point 1 hold as published, with two refinements the
consumers should adopt — import `RetryDelay` from `Keiro.PGMQ` (not shibuya), and treat the
delay argument of `enqueueWithDelay` as `Int32`.

What remains: nothing for EP-1. Next in the MasterPlan are EP-2 (`rei`) and EP-3
(`hospital-capacity`), which may proceed in parallel now that the package and its API are
real.


## Context and Orientation

You are working in the keiro repository at `/Users/shinzui/Keikaku/bokuno/keiro`. It is a
Haskell project built with `cabal`, containing several library packages declared in the
root `cabal.project`. The existing packages are `keiro` (the framework runtime),
`keiro-core` (dependency-light contracts), `keiro-migrations`, `keiro-test-support` (shared
PostgreSQL test fixtures), and `jitsurei` (an example app). You will add a new package,
`keiro-pgmq`, alongside them.

This package depends on three external projects that are pinned into the build (their
sources live on disk; see "Build/dependency facts" below). You do not modify them; you only
import from them:

- `pgmq-core` and `pgmq-effectful` — the PGMQ client. Key module `Pgmq.Effectful` exposes
  the `Pgmq` effect and operations; `Pgmq.Types` (from `pgmq-core`) exposes wire types.
- `shibuya-core` — the worker framework. Key modules: `Shibuya.App` (the supervised
  runner), `Shibuya.Adapter` (the `Adapter` type), `Shibuya.Core.Ingested`,
  `Shibuya.Core.Ack`, `Shibuya.Core.Types`, `Shibuya.Telemetry.Effect` (the `Tracing`
  effect).
- `shibuya-pgmq-adapter` — the bridge. Key modules: `Shibuya.Adapter.Pgmq` (the
  `pgmqAdapter` function) and `Shibuya.Adapter.Pgmq.Config` (`PgmqAdapterConfig`,
  `defaultConfig`, `directDeadLetter`).
- `keiro-core` — for the optional versioned-codec bridge; key module `Keiro.Codec`.

The exact signatures you will rely on are reproduced verbatim in "Interfaces and
Dependencies" so you do not have to go read those projects. If you do want to read them,
their on-disk locations are listed there too.

Terms used in this plan:

- **Effect / effect stack**: with `effectful`, code runs in `Eff es a` where `es` is a list
  of capabilities. `(Pgmq :> es)` means "the `Pgmq` capability is available in `es`".
  "Running" an effect means interpreting it away with a function like `runPgmq`.
- **Adapter** (shibuya): a record `Adapter es msg` holding a stream of messages and a
  shutdown action. `pgmqAdapter` builds one for a PGMQ queue; `msg` is always
  `aeson`'s `Value` (raw JSON) for PGMQ.
- **Ingested / Envelope / AckDecision** (shibuya): a message handed to a handler is an
  `Ingested es msg` whose `envelope` field is an `Envelope msg` carrying `payload :: msg`
  (the JSON), `attempt`, `messageId`, etc. A handler returns an `AckDecision`:
  `AckOk` (delete), `AckRetry (RetryDelay t)` (redeliver after `t`),
  `AckDeadLetter reason` (park in DLQ), or `AckHalt reason` (stop the processor).
- **QueueName** (pgmq): a validated newtype over `Text`. PGMQ rejects names containing dots
  and caps length at 47 characters. This is why apps need a logical-to-physical name
  derivation — a footgun this package will own once, centrally.


## Plan of Work

The work is five milestones. Each is independently verifiable: milestones 1–4 end with
`cabal build keiro-pgmq` succeeding; milestone 5 ends with `cabal test keiro-pgmq` passing.

### Milestone 1 — Scaffold the package

Create the package so an empty library compiles and is visible to the build. At the end,
`cabal build keiro-pgmq` succeeds against a stub module.

Create the directory `keiro-pgmq/` with this layout (mirroring `keiro-core/`):

```text
keiro-pgmq/
  keiro-pgmq.cabal
  src/Keiro/PGMQ.hs            -- umbrella re-export (stub for now)
  src/Keiro/PGMQ/Runtime.hs    -- stub for now
  src/Keiro/PGMQ/Codec.hs      -- stub for now
  src/Keiro/PGMQ/Job.hs        -- stub for now
```

Write `keiro-pgmq/keiro-pgmq.cabal` modeled on `keiro-core/keiro-core.cabal` (reproduced in
Interfaces and Dependencies). Use the same `common warnings` and `common shared` stanzas
(`default-language: GHC2024`, the same `default-extensions` and warning flags). Set:

```cabal
cabal-version: 3.0
name:          keiro-pgmq
version:       0.1.0.0
synopsis:      PostgreSQL job-queue (PGMQ) integration for Keiro
```

`exposed-modules` for the library:

```cabal
  exposed-modules:
    Keiro.PGMQ
    Keiro.PGMQ.Runtime
    Keiro.PGMQ.Codec
    Keiro.PGMQ.Job
```

`build-depends` for the library (versions can mirror those used elsewhere in the repo; if a
bound is unknown, copy the bound from the package that already depends on it):

```cabal
  build-depends:
    , aeson                 >=2.2
    , base                  >=4.21 && <5
    , bytestring            >=0.11
    , effectful             >=2.6
    , effectful-core        >=2.6
    , hasql-pool            >=1.2
    , hs-opentelemetry-api  >=1.0  && <1.1
    , keiro-core            >=0.1
    , pgmq-core
    , pgmq-effectful
    , shibuya-core          >=0.5
    , shibuya-pgmq-adapter
    , streamly-core         >=0.3
    , text                  >=2.1
    , time                  >=1.12
```

Register the package in two places:

1. Root `cabal.project` — add `keiro-pgmq` to the `packages:` list. The
   `source-repository-package` pins for `pgmq-*` and `shibuya-pgmq-adapter` must be present
   so the new dependencies resolve; if they are not already pinned in keiro's
   `cabal.project`, add them, copying the exact `location`/`tag`/`subdir` form that
   `keiro-runtime-jitsurei`'s `cabal.project` uses (see Interfaces and Dependencies for the
   pin shapes). Note: keiro currently pins `keiki`, `kiroku`, and `codd` but **not** the
   pgmq/shibuya family, so you will be adding those `source-repository-package` stanzas.
2. `mori.dhall` — add a `keiro-pgmq` entry to the `packages` array (snippet in Interfaces
   and Dependencies).

Make `src/Keiro/PGMQ/Runtime.hs`, `Codec.hs`, `Job.hs` compile as empty modules
(`module Keiro.PGMQ.Runtime where`) and `src/Keiro/PGMQ.hs` re-export nothing yet
(`module Keiro.PGMQ () where`).

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, run `cabal build keiro-pgmq` and see
it compile with no errors.

### Milestone 2 — `Keiro.PGMQ.Runtime` (layer 1, transport-agnostic)

This layer owns the two things every PGMQ integration repeats and that case B (future) will
also need: turning an arbitrary logical name into a PGMQ-legal `QueueName` + DLQ name, and
running the `Pgmq : Tracing : Error : IOE` effect stack with an optional OpenTelemetry
tracer.

In `src/Keiro/PGMQ/Runtime.hs` define:

```haskell
-- | A logical queue identity plus the PGMQ-legal physical names derived from it.
data QueueRef = QueueRef
  { logicalName  :: !Text            -- ^ caller-facing; may contain dots / illegal chars
  , physicalName :: !Pgmq.QueueName  -- ^ derived, PGMQ-valid (used for the main queue)
  , dlqName      :: !Pgmq.QueueName  -- ^ derived "<physical>_dlq"
  }
  deriving stock (Eq, Show)

-- | Derive a QueueRef from a logical name. Total: it sanitizes rather than failing.
-- Lower-cases, replaces every character that is not [a-z0-9_] with '_', collapses
-- repeated underscores, trims to fit PGMQ's 47-char ceiling (leaving room for the
-- "_dlq" suffix and PGMQ's own internal prefixes), and guarantees a leading letter.
queueRef :: Text -> QueueRef
```

Implement `queueRef` so that, e.g., `queueRef "hospital_capacity.reservation_work"` yields
`physicalName = "hospital_capacity_reservation_work"` and
`dlqName = "hospital_capacity_reservation_work_dlq"`. Build the `Pgmq.QueueName` values with
`Pgmq.parseQueueName` and treat a parse failure as a programmer error (the sanitizer should
never produce an invalid name; if it somehow does, `error` with a clear message is
acceptable here because the input is a compile-time-ish constant). Keep the 47-char cap in
mind: reserve at least 4 characters so the `_dlq` suffix still fits.

Define the runtime handle and runners:

```haskell
-- | Opaque runtime: a hasql connection pool plus an optional tracer.
data JobRuntime = JobRuntime
  { runtimePool   :: !Pool          -- ^ Hasql.Pool.Pool
  , runtimeTracer :: !(Maybe OTel.Tracer)
  }

-- | Acquire a pool from a connection string, run the action, release the pool.
withJobRuntime :: Text -> Maybe OTel.Tracer -> (JobRuntime -> IO a) -> IO a

-- | Run a Pgmq + Tracing effect action against the runtime, surfacing PGMQ errors.
-- Threads the tracer into BOTH the shibuya Tracing effect and the pgmq interpreter:
--   * Nothing  -> runTracingNoop + runPgmq
--   * Just tr  -> runTracing tr  + runPgmqTraced pool tr
runJobEff
  :: JobRuntime
  -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] a
  -> IO (Either PgmqRuntimeError a)
```

The ordering of interpreters matters: `runPgmq`/`runPgmqTraced` require `Error
PgmqRuntimeError :> es` and `IOE :> es`, so peel `Pgmq` first, then `Tracing`, then `Error`,
then `IOE`. Concretely:

```haskell
runJobEff JobRuntime{runtimePool, runtimeTracer} act =
  runEff
    . runErrorNoCallStack @PgmqRuntimeError
    $ case runtimeTracer of
        Nothing -> runTracingNoop (runPgmq runtimePool act)
        Just tr -> runTracing tr  (runPgmqTraced runtimePool tr act)
```

(Confirm the exact `Error` runner name — `runErrorNoCallStack` vs `runError` — against the
`effectful` version in `cabal.project`; both exist, `runErrorNoCallStack` returns
`Either e a` without a callstack and matches how `keiro-runtime-jitsurei` does it.)

Acceptance: `cabal build keiro-pgmq` succeeds; add a tiny `ghci`-checkable example or a
doctest-style comment showing `physicalName (queueRef "a.b.c") == QueueName "a_b_c"`. (A
real assertion lands in the milestone-5 test; here, compilation is the gate.)

### Milestone 3 — `Keiro.PGMQ.Codec`

In `src/Keiro/PGMQ/Codec.hs` define the payload codec used by `Job`:

```haskell
-- | How a job payload is turned into PGMQ JSON and back.
data JobCodec p = JobCodec
  { encodeJob :: p -> Value
  , decodeJob :: Value -> Either Text p
  }

-- | The default: raw aeson. Drop-in for apps that already use ToJSON/FromJSON payloads.
aesonJobCodec :: (ToJSON p, FromJSON p) => JobCodec p
aesonJobCodec = JobCodec toJSON (first Text.pack . parseEither parseJSON)

-- | Versioned bridge to keiro's Keiro.Codec. Wraps payloads as
-- @{ "v": <schemaVersion>, "data": <encode codec p> }@ and, on decode, reads the version,
-- runs the codec's upcaster chain to the current version, then decodes.
keiroJobCodec :: Codec p -> JobCodec p
```

For `keiroJobCodec`, use the `Keiro.Codec` fields directly (signatures in Interfaces and
Dependencies): on encode, produce `object ["v" .= schemaVersion codec, "data" .= encode
codec p]`; on decode, parse the wrapper, then call `migrateToCurrent codec v dataValue`
(which applies upcasters) and finally `decode codec` on the migrated value, mapping
`CodecError` to `Text` via `show`. This gives job payloads the same schema-evolution story
event streams already have.

Acceptance: `cabal build keiro-pgmq` succeeds. A round-trip property
(`decodeJob c (encodeJob c x) == Right x`) for `aesonJobCodec` is asserted in milestone 5.

### Milestone 4 — `Keiro.PGMQ.Job` (layer 2, the ergonomics)

This is the payoff layer. In `src/Keiro/PGMQ/Job.hs` define:

```haskell
-- | What a job handler decides. Never exposes shibuya/PGMQ wire types to the caller.
data JobOutcome
  = Done            -- ^ processed; delete from queue
  | Retry !RetryDelay  -- ^ leave on queue; redeliver after the delay
  | Dead !Text      -- ^ poison; route to the DLQ with this reason
  deriving stock (Show)

data RetryPolicy = RetryPolicy
  { maxRetries        :: !Int64       -- ^ deliveries before auto-DLQ (PGMQ readCount)
  , defaultRetryDelay :: !RetryDelay  -- ^ used when a handler returns Retry with no delay
  , useDeadLetter     :: !Bool        -- ^ create + route to a DLQ
  }

defaultRetryPolicy :: RetryPolicy
defaultRetryPolicy = RetryPolicy { maxRetries = 5, defaultRetryDelay = RetryDelay 60, useDeadLetter = True }

data Job p = Job
  { jobName   :: !Text          -- ^ ProcessorId + telemetry label
  , jobQueue  :: !QueueRef
  , jobCodec  :: !(JobCodec p)
  , jobPolicy :: !RetryPolicy
  }
```

Then the operations:

```haskell
-- Producer. Encodes with the job's codec and sends to the queue's physical name.
enqueue :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es Pgmq.MessageId
enqueueWithDelay :: (Pgmq :> es, IOE :> es) => Job p -> Pgmq.Delay -> p -> Eff es Pgmq.MessageId

-- Idempotent: create the main queue, and the DLQ if the policy uses one.
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()

-- Build a shibuya processor: pgmqAdapter (configured from the job's policy) + a wrapped
-- handler that decodes the payload and maps JobOutcome -> AckDecision.
jobProcessor
  :: (Pgmq :> es, IOE :> es, Tracing :> es)
  => Job p -> (p -> Eff es JobOutcome)
  -> Eff es (ProcessorId, QueueProcessor es)

-- Continuous, multi-processor (rei cadence): run a supervised app over several processors.
runJobWorkers
  :: (Pgmq :> es, IOE :> es, Tracing :> es)
  => SupervisionStrategy -> Int
  -> [Eff es (ProcessorId, QueueProcessor es)]
  -> Eff es (Either AppError (AppHandle es))

-- One-shot drain of up to n messages (hospital-capacity cadence): take n from the adapter
-- source, run the wrapped handler over each, then stop.
runJobOnce
  :: (Pgmq :> es, IOE :> es, Tracing :> es)
  => Int -> Job p -> (p -> Eff es JobOutcome) -> Eff es ()
```

Implementation notes:

- `enqueue job p = sendMessage SendMessage { queueName = physicalName (jobQueue job),
  messageBody = MessageBody (encodeJob (jobCodec job) p), delay = Nothing }`.
  `enqueueWithDelay` sets `delay = Just d`.
- `ensureJobQueue job = do createQueue (physicalName (jobQueue job)); when (useDeadLetter
  (jobPolicy job)) (createQueue (dlqName (jobQueue job)))`. `Pgmq.createQueue` is
  idempotent in PGMQ (safe to call repeatedly). (`keiro-runtime-jitsurei` calls
  `Pgmq.createQueue` directly inside a `runPgmq` block, confirming it is an effectful op of
  signature `QueueName -> Eff es ()`.)
- Build the adapter config from the policy:
  `(defaultConfig (physicalName (jobQueue job))) { maxRetries = maxRetries (jobPolicy job),
  deadLetterConfig = if useDeadLetter (jobPolicy job) then Just (directDeadLetter (dlqName
  (jobQueue job)) True) else Nothing }`.
- `jobProcessor job handle = do adapter <- pgmqAdapter (configFor job); let wrapped =
  wrapHandler job handle; pure (ProcessorId (jobName job), mkProcessor adapter wrapped)`.
- `wrapHandler` is the boilerplate absorbed once:

```haskell
wrapHandler :: Job p -> (p -> Eff es JobOutcome) -> (Ingested es Value -> Eff es AckDecision)
wrapHandler job handle ingested =
  case decodeJob (jobCodec job) (payload (envelope ingested)) of
    Left err -> pure (AckDeadLetter (InvalidPayload err))
    Right p  -> toAck (jobPolicy job) <$> handle p
  where
    toAck _      Done        = AckOk
    toAck policy (Retry d)   = AckRetry d
    toAck _      (Dead why)  = AckDeadLetter (PoisonPill why)
```

  (If `Retry` should fall back to `defaultRetryDelay` when a handler passes a zero/blank
  delay, encode that in `toAck`. Keeping `Retry !RetryDelay` explicit is simplest; provide
  a convenience `retryDefault :: Job p -> JobOutcome` if helpful.)

- `runJobWorkers strat cap procs = do ps <- sequence procs; runApp strat cap ps`.
  `runApp` returns `Eff es (Either AppError (AppHandle es))`; the caller decides whether to
  block on the handle.
- `runJobOnce n job handle = do (_pid, _qp) <- jobProcessor job handle; ...` — but for a
  true one-shot drain, follow `hospital-capacity`'s pattern of building the adapter, taking
  `n` from its `source` stream, and folding the wrapped handler over each `Ingested`,
  calling `finalize (ack ingested)` with the resulting `AckDecision`. Reproduce that loop
  here so callers don't. (See `keiro-runtime-jitsurei`'s `WorkQueue.hs`
  `runReservationWorkConsumerOnceWithTelemetry` for the shape: `Stream.take n source`, then
  process. The exact streamly combinators are in `shibuya-core`'s `Shibuya.Stream`.)

Finally, make `src/Keiro/PGMQ.hs` re-export the public surface:

```haskell
module Keiro.PGMQ
  ( module Keiro.PGMQ.Runtime
  , module Keiro.PGMQ.Codec
  , module Keiro.PGMQ.Job
  ) where
```

Acceptance: `cabal build keiro-pgmq` succeeds with the full public API.

### Milestone 5 — Integration test

Prove the package works end-to-end against a real PostgreSQL with PGMQ installed. Add a
`test-suite keiro-pgmq-test` to the cabal file (type `exitcode-stdio-1.0`, `hspec`),
`hs-source-dirs: test`, `main-is: Main.hs`.

The test must NOT use `keiro-test-support`'s `withMigratedSuite` — that fixture installs
the kiroku/keiro event-store schema, not PGMQ. Instead, stand up a throwaway PostgreSQL
with `ephemeral-pg` (already a dependency of `keiro-test-support`, so it is in the build
plan) and install the PGMQ schema with `pgmq-migration` (the `Pgmq.Migration` module
installs PGMQ without requiring the Postgres extension). Read `pgmq-migration`'s exposed
module to get the exact migrate entrypoint — its source is at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration`. Add
`ephemeral-pg`, `pgmq-migration`, `hasql`, `hasql-pool`, and `hspec` to the test stanza's
`build-depends`.

Test scenarios (each in its own `it`):

1. **Round-trip codec**: `decodeJob aesonJobCodec (encodeJob aesonJobCodec x) == Right x`
   for a sample payload type defined in the test.
2. **Done deletes**: define `Job` with a test queue; `ensureJobQueue`; `enqueue` one
   message; `runJobOnce 1 job (\_ -> pure Done)`; assert the queue is now empty (read with
   `pgmq-effectful`'s read/metrics op and expect zero messages).
3. **Retry redelivers**: enqueue one; `runJobOnce 1 job (\_ -> pure (Retry (RetryDelay 0)))`;
   assert the message is still present / becomes visible again (read with visibility 0 and
   expect it back).
4. **Dead routes to DLQ**: enqueue one; `runJobOnce 1 job (\_ -> pure (Dead "bad"))`; assert
   the main queue is empty and the DLQ has one message.
5. **Bad payload → DLQ**: `enqueue` a raw `Value` that the codec rejects (send via the
   low-level `sendMessage` with garbage), drain once, assert it lands in the DLQ
   (the `wrapHandler` decode-failure path).

Drive all PGMQ effects through `runJobEff` (milestone 2) against a `JobRuntime` built from
the ephemeral server's connection string with `Nothing` tracer.

Acceptance: from `/Users/shinzui/Keikaku/bokuno/keiro`, `cabal test keiro-pgmq` prints all
examples passing.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.

```bash
# Milestone 1: scaffold
mkdir -p keiro-pgmq/src/Keiro/PGMQ
# (create keiro-pgmq.cabal and the four stub modules per Plan of Work)
# (edit cabal.project: add `keiro-pgmq` to packages: and add pgmq/shibuya source-repository-package pins)
# (edit mori.dhall: add the keiro-pgmq package entry)
cabal build keiro-pgmq
```

Expected after milestone 1:

```text
Resolving dependencies...
Build profile: ...
 - keiro-pgmq-0.1.0.0 (lib) (first run)
Building library for keiro-pgmq-0.1.0.0..
```

```bash
# Milestones 2-4: fill in modules, rebuilding after each
cabal build keiro-pgmq
```

```bash
# Milestone 5: test
cabal test keiro-pgmq
```

Expected after milestone 5 (abridged):

```text
Keiro.PGMQ
  codec round-trips [✔]
  Done deletes the message [✔]
  Retry redelivers the message [✔]
  Dead routes to the DLQ [✔]
  undecodable payload routes to the DLQ [✔]
Finished in N seconds
5 examples, 0 failures
```

After each milestone, commit. Every commit must carry all three trailers:

```text
Scaffold keiro-pgmq package

MasterPlan: docs/masterplans/7-keiro-pgmq-reusable-postgres-job-queue.md
ExecPlan: docs/plans/55-build-the-keiro-pgmq-package-with-typed-job-and-runtime-layers.md
Intention: intention_01kthhpasxesx8hp84264cjhpx
```


## Validation and Acceptance

The package is accepted when `cabal build keiro-pgmq` and `cabal test keiro-pgmq` both
succeed from the repo root, and the five integration scenarios above pass. Beyond
compilation, the proof is behavioral: an enqueued message that a handler marks `Done`
disappears from the queue; one marked `Retry` comes back; one marked `Dead` (or one that
fails to decode) appears in the DLQ. These assertions are read back through `pgmq-effectful`
against a real PostgreSQL, so they exercise the whole path (`enqueue` → `pgmqAdapter` →
`wrapHandler` → ack → PGMQ side effect), not just type-checking.

The two consumer migrations (`docs/plans/56-...` and `docs/plans/57-...`) are the ultimate
acceptance: when both compile and keep their behavior using only this package's API, the
abstraction is proven against two real cadences.


## Idempotence and Recovery

Every step is safe to repeat. The cabal scaffold is additive; re-running `cabal build` is
idempotent. `ensureJobQueue` calls `Pgmq.createQueue`, which PGMQ makes idempotent, so it
is safe to call at every worker startup. The integration test creates its queues with
unique names per run (suffix with a counter or the ephemeral server's port) so repeated
runs never collide; if you cannot guarantee unique names, the test should drop its queues at
the start with `dropQueue` (ignoring "does not exist"). If a milestone half-lands and the
build breaks, the stub-module approach means you can always return modules to empty
(`module X where`) to get back to a green build, then re-fill.


## Interfaces and Dependencies

All signatures below are reproduced from the dependency sources so this plan is
self-contained. On-disk locations are given if you want to read more.

### keiro build facts (this repo)

Existing `keiro-core/keiro-core.cabal` to model the new cabal file on (key stanzas):

```cabal
cabal-version: 3.0
name:          keiro-core
version:       0.1.0.0
build-type:    Simple
tested-with:   GHC >=9.12 && <9.13

common warnings
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-record-updates
    -Wincomplete-uni-patterns -Wpartial-fields -Wredundant-constraints

common shared
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
    PackageImports

library
  import:          warnings, shared
  exposed-modules: ...
  hs-source-dirs:  src
  build-depends:   ...
```

Root `cabal.project` currently contains `packages: keiro keiro-core keiro-migrations
keiro-test-support jitsurei` and `source-repository-package` git pins for `keiki`
(+`keiki-codec-json`), `kiroku-store` (+`kiroku-store-migrations`), and `codd`. It does
**not** yet pin the pgmq/shibuya family — you will add those. The pin form used by
`keiro-runtime-jitsurei`'s `cabal.project` (copy this shape, adjusting `location` to the
on-disk paths or upstream git as appropriate):

```text
source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
  tag: <sha>
  subdir: pgmq-core

source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
  tag: <sha>
  subdir: pgmq-effectful

source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs
  tag: <sha>
  subdir: pgmq-migration

source-repository-package
  type: git
  location: file:///Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
  tag: <sha>
  subdir: shibuya-pgmq-adapter
```

`shibuya-core` is a subdir of the shibuya repo at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`; pin it the same way if keiro does
not already get it transitively. Resolve `<sha>` to the current checked-out commit of each
on-disk repo (run `git -C <path> rev-parse HEAD`).

`mori.dhall` packages array entry to add:

```dhall
, Schema.Package::{
  , name = "keiro-pgmq"
  , type = Schema.PackageType.Library
  , language = Schema.Language.Haskell
  , description = Some "PostgreSQL job-queue (PGMQ) integration for Keiro"
  }
```

### Keiro.Codec (keiro-core/src/Keiro/Codec.hs)

```haskell
type Upcaster = (Int, Value -> Either Text Value)

data Codec e = Codec
  { eventTypes    :: !(NonEmpty Text)
  , eventType     :: !(e -> Text)
  , schemaVersion :: !Int
  , encode        :: !(e -> Value)
  , decode        :: !(Value -> Either Text e)
  , upcasters     :: ![Upcaster]
  }

migrateToCurrent :: Codec e -> Int -> Value -> Either CodecError Value
-- (also available: encodeForAppend, decodeRecorded, decodeRaw — these target kiroku's
--  EventData/RecordedEvent and are NOT what the Job codec needs; use the raw fields above.)
```

### pgmq-effectful / pgmq-core

```haskell
-- Pgmq.Effectful (interpreters)
runPgmq        :: (IOE :> es, Error PgmqRuntimeError :> es) => Pool -> Eff (Pgmq : es) a -> Eff es a
runPgmqTraced  :: (IOE :> es, Error PgmqRuntimeError :> es) => Pool -> OTel.Tracer -> Eff (Pgmq : es) a -> Eff es a

-- Pgmq.Effectful (operations — effectful ops of the Pgmq effect)
sendMessage :: SendMessage -> Eff es Pgmq.MessageId
createQueue :: QueueName  -> Eff es ()        -- idempotent in PGMQ
dropQueue   :: QueueName  -> Eff es ()
-- (read/metrics ops exist for the test's assertions; consult Pgmq.Effectful's export list,
--  e.g. readMessage / queueMetrics, for reading back queue contents.)

-- Pgmq.Hasql.Statements.Types
data SendMessage = SendMessage
  { queueName   :: !QueueName
  , messageBody :: !MessageBody
  , delay       :: !(Maybe Delay)
  }

-- Pgmq.Types (pgmq-core)
newtype MessageBody = MessageBody { unMessageBody :: Value }
newtype MessageId   = MessageId   { unMessageId   :: Int64 }
newtype QueueName   = QueueName Text
parseQueueName  :: Text -> Either PgmqError QueueName    -- rejects dots; <=47 chars
queueNameToText :: QueueName -> Text
```

On disk: `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`.

### shibuya-core

```haskell
-- Shibuya.App
data SupervisionStrategy = IgnoreFailures | StopAllOnFailure
runApp      :: (IOE :> es, Tracing :> es) => SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
-- Handler es msg is the function type (Ingested es msg -> Eff es AckDecision).
newtype ProcessorId = ProcessorId { unProcessorId :: Text }

-- Shibuya.Adapter
data Adapter es msg = Adapter { adapterName :: !Text, source :: Stream (Eff es) (Ingested es msg), shutdown :: Eff es () }

-- Shibuya.Core.Ingested
data Ingested es msg = Ingested { envelope :: !(Envelope msg), ack :: !(AckHandle es), lease :: !(Maybe (Lease es)) }

-- Shibuya.Core.Types
data Envelope msg = Envelope { messageId :: !MessageId, cursor :: !(Maybe Cursor), partition :: !(Maybe Text)
                             , enqueuedAt :: !(Maybe UTCTime), traceContext :: !(Maybe TraceHeaders)
                             , headers :: !(Maybe Headers), attempt :: !(Maybe Attempt)
                             , attributes :: !(HashMap Text Attribute), payload :: !msg }

-- Shibuya.Core.Ack
data AckDecision = AckOk | AckRetry !RetryDelay | AckDeadLetter !DeadLetterReason | AckHalt !HaltReason
newtype RetryDelay = RetryDelay { unRetryDelay :: NominalDiffTime }
data DeadLetterReason = PoisonPill !Text | InvalidPayload !Text | MaxRetriesExceeded

-- Shibuya.Core.AckHandle
newtype AckHandle es = AckHandle { finalize :: AckDecision -> Eff es () }

-- Shibuya.Telemetry.Effect
data Tracing :: Effect
runTracing     :: (IOE :> es) => OTel.Tracer -> Eff (Tracing : es) a -> Eff es a
runTracingNoop :: (IOE :> es) => Eff (Tracing : es) a -> Eff es a
```

On disk: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`.

### shibuya-pgmq-adapter

```haskell
-- Shibuya.Adapter.Pgmq
pgmqAdapter :: (Pgmq :> es, IOE :> es, Tracing :> es) => PgmqAdapterConfig -> Eff es (Adapter es Value)

-- Shibuya.Adapter.Pgmq.Config
data PgmqAdapterConfig = PgmqAdapterConfig
  { queueName         :: !QueueName
  , visibilityTimeout :: !Int32
  , batchSize         :: !Int32
  , polling           :: !PollingConfig
  , deadLetterConfig  :: !(Maybe DeadLetterConfig)
  , maxRetries        :: !Int64
  , fifoConfig        :: !(Maybe FifoConfig)
  , prefetchConfig    :: !(Maybe PrefetchConfig)
  }
defaultConfig    :: QueueName -> PgmqAdapterConfig
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig   -- (dlqQueue, includeMetadata)
data DeadLetterTarget = DirectQueue !QueueName | TopicRoute !RoutingKey
```

On disk: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter`.

### Tracer type

`OTel.Tracer` is `OpenTelemetry.Trace.Core.Tracer` from `hs-opentelemetry-api`. Code that
does not have a tracer passes `Nothing` and gets the noop path.

### What this milestone set must yield

At the end of milestone 4 the following must exist and type-check (these are the exact
signatures the two migrations depend on; they are mirrored in the MasterPlan's Integration
Points and must be kept in sync if changed):

```haskell
-- Keiro.PGMQ.Runtime
data QueueRef
queueRef       :: Text -> QueueRef
data JobRuntime
withJobRuntime :: Text -> Maybe OTel.Tracer -> (JobRuntime -> IO a) -> IO a
runJobEff      :: JobRuntime -> Eff '[Pgmq, Tracing, Error PgmqRuntimeError, IOE] a -> IO (Either PgmqRuntimeError a)

-- Keiro.PGMQ.Codec
data JobCodec p
aesonJobCodec  :: (ToJSON p, FromJSON p) => JobCodec p
keiroJobCodec  :: Codec p -> JobCodec p

-- Keiro.PGMQ.Job
data JobOutcome = Done | Retry !RetryDelay | Dead !Text
data RetryPolicy
defaultRetryPolicy :: RetryPolicy
data Job p
enqueue        :: (Pgmq :> es, IOE :> es) => Job p -> p -> Eff es Pgmq.MessageId
ensureJobQueue :: (Pgmq :> es) => Job p -> Eff es ()
jobProcessor   :: (Pgmq :> es, IOE :> es, Tracing :> es) => Job p -> (p -> Eff es JobOutcome) -> Eff es (ProcessorId, QueueProcessor es)
runJobWorkers  :: (Pgmq :> es, IOE :> es, Tracing :> es) => SupervisionStrategy -> Int -> [Eff es (ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))
runJobOnce     :: (Pgmq :> es, IOE :> es, Tracing :> es) => Int -> Job p -> (p -> Eff es JobOutcome) -> Eff es ()
```
