---
id: 137
slug: guarantee-deterministic-consumer-close-in-hw-kafka-streamly
title: "Guarantee deterministic consumer close in hw-kafka-streamly"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md"
---

# Guarantee deterministic consumer close in hw-kafka-streamly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`hw-kafka-streamly` (`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`) offers
`kafkaStream` and `kafkaStreamAutoClose`, which promise to close the Kafka consumer
"when the stream ends". That promise is broken in the most common real usage: when
the stream is *partially consumed and abandoned* — for example `Stream.take 5` over
the stream, which is exactly what the module's own worked example does — streamly's
`bracketIO` defers the cleanup to the garbage collector. Until some GC happens to
run (possibly never in a quiet process; never at process exit, which runs no
finalizers), the consumer is a zombie: `hw-kafka-client`'s background loop keeps
polling every 100 ms, which keeps the group membership alive, keeps the partitions
assigned to the zombie, and keeps resetting librdkafka's `max.poll.interval.ms`
progress watchdog — so the abandoned partitions are starved, silently, with no
rebalance. This is finding KSC-7 of the July 2026 consumer-stack review, verified
against streamly-core, hw-kafka-client, and librdkafka sources (citations in
Context and Orientation).

After this plan, the library ships a scope-based entry point —
`withKafkaConsumerStream` — that guarantees the consumer is closed when the scope
exits, no matter how much of the stream was consumed; the worked example uses it;
the legacy entry points carry a prominent GC-deferral warning; and a regression
test proves the close happens deterministically under `take`-style abandonment.
You can see it working by running the new test (it fails against a
`bracketIO`-based implementation and passes against the scope-based one) and by
reading the fixed example, which now cannot leak a consumer.

This plan is EP-3 of MasterPlan 23
(`docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md`).
It is independent of its siblings except for release mechanics: sibling plan
`docs/plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md` also
edits `src/Kafka/Streamly/Stream.hs` (disjoint sections: its `isFatal` arms, this
plan's bracket API) and `test/Kafka/Streamly/StreamTest.hs`; both land in one
`hw-kafka-streamly` release — whichever plan lands second cuts it. Sibling
`docs/plans/136-classify-poll-and-commit-errors-and-fix-traced-context-hygiene.md`
does not touch this repo. No registered project depends on `hw-kafka-streamly`
(`mori registry dependents shinzui/hw-kafka-streamly` reports none), so nothing
downstream can break.


## Progress

- [ ] M1: `withKafkaConsumerStream` (and the injectable internal helper) implemented;
      module worked example rewritten to use it; GC-deferral warnings added to
      `kafkaStream` and `kafkaStreamAutoClose` haddocks.
- [ ] M2: Zombie regression test added (close-flag determinism under `take`
      abandonment, against a real broker-less consumer) and green; failure mode
      demonstrated against a bracketIO-based variant and transcript captured.
- [ ] M3: CHANGELOG updated; deprecation posture recorded; release coordinated with
      plan 135; optional broker-backed group-membership verification executed.


## Surprises & Discoveries

Findings from plan-authoring verification (2026-07-23):

- `streamly-core`'s own documentation recommends the scope-based approach this plan
  ships. At the resolved version 0.3.0 (verified in
  `dist-newstyle/cache/plan.json`; Hackage tarball inspected), `bracketIO`'s haddock
  lists the worst cases — "cleanup is deferred to GC: the bracketed stream is
  partially consumed and abandoned; pipeline is aborted due to an exception outside
  the bracket" (`src/Streamly/Internal/Data/Stream/Exception.hs:400-409` in the
  0.3.0/0.3.1 tarballs; the 0.4.0 corpus at
  `/Users/shinzui/Keikaku/hub/haskell/streamly-project/streamly` has the same text
  at `core/src/Streamly/Internal/Data/Stream/Exception.hs:396-414`, plus an explicit
  "take on a bracketed stream terminates without draining" bullet at 372–374) — and
  points to `Streamly.Control.Exception.withAcquireIO` "for covering the entire
  pipeline with guaranteed cleanup at the end of bracket".
- `withAcquireIO` and the fusible `bracketIO'` *do* exist at the pinned
  streamly-core 0.3.0 (the review asked to check 0.3 vs 0.4): the 0.3.0 changelog
  lists "APIs for prompt cleanup of resources", `Streamly.Control.Exception`
  exports `withAcquireIO` (line 31 of that module in the 0.3.0 tarball), and
  `Streamly.Data.Stream` publicly exports `bracketIO'`/`bracketIO''`. Their
  guarantee is "cleanup at the end of the *monad-level* bracket" — i.e. still at
  scope exit, not at abandonment point. This plan's design needs only scope-exit
  semantics, which plain `Control.Exception.bracket` already provides without any
  new streamly machinery; see the Decision Log for why the plain bracket wins.
- Exceptions *inside* stream generation already close promptly today: streamly's
  bracket runs the cleanup on exceptions raised while the stream itself is
  executing, and normal termination (fatal error ends `kafkaStreamNoClose`) runs
  cleanup + `closeConsumer`, which performs librdkafka's final auto-commit. The
  defect is exclusively the abandonment/downstream-exception path. (Verified
  against the 0.3.x/0.4.0 `bracketIO` docs and `gbracket` implementation notes —
  the GC hook is `newIOFinalizer`.)
- The zombie cannot even be collected by the rd_kafka handle's own GC finalizer
  while the loop runs: hw-kafka-client's finalizer
  (`src/Kafka/Internal/RdKafka.chs:860-877`, `rd_kafka_destroy_flags` with
  `RD_KAFKA_DESTROY_F_NO_CONSUMER_CLOSE` = 0x8) fires only when the handle is
  unreachable, and the background loop (`src/Kafka/Consumer.hs:432-440`) holds the
  handle until `closeConsumer` flips the status MVar (`closeConsumer`,
  lines 346–356, is the sole writer of `CallbackPollDisabled`). So "GC will
  eventually fix it" is doubly false: the stream finalizer needs a GC that may not
  come, and the handle finalizer cannot fire at all until the stream finalizer has
  run `closeConsumer`.


## Decision Log

- Decision: Ship a with-style scope function implemented with plain
  `Control.Exception.bracket` — not with streamly's `withAcquireIO`/`bracketIO'`
  machinery.
  Rationale: The consumer is used only within the callback's scope, so scope-exit
  close is exactly `bracket newConsumer closeConsumer`; it adds no new dependency
  surface, works identically at streamly-core 0.3.0 and 0.4.x (no version gymnastics
  in a library that declares `streamly-core >=0.3 && <0.5`), and its semantics are
  obvious to a reviewer. `withAcquireIO` + `bracketIO'` provides the same scope-exit
  guarantee with extra machinery whose payoff (stream fusion through the bracket,
  multi-resource registration) this API does not need: the poll loop's cost is
  dominated by FFI polling, not fusion. Recorded alternative: if a future version
  wants a `Stream`-returning API with prompt-at-abandonment cleanup, streamly-core
  0.3.0's `bracketIO'`+`withAcquireIO` is the upgrade path; the haddock of the new
  function points there.
  Date: 2026-07-23

- Decision: The new API is `withKafkaConsumerStream` (properties + subscription,
  fully managed) plus `withKafkaConsumerStreamOn` (caller-supplied consumer, close
  still guaranteed by the scope), both built on one internal helper with an
  injectable close action for testability.
  Rationale: Mirrors the module's existing two managed tiers (`kafkaStream` /
  `kafkaStreamAutoClose`) so migration is mechanical; the injectable helper lets the
  regression test observe "close ran, exactly once, before scope return" with a real
  `KafkaConsumer` and no broker, without exposing test hooks in the public API.
  Date: 2026-07-23

- Decision: Keep `kafkaStream` and `kafkaStreamAutoClose` undeprecated (no
  `DEPRECATED` pragma) in this release; add loud haddock warnings and cross-links
  instead.
  Rationale: The functions are correct when the stream is consumed to completion
  (their cleanup also handles in-stream exceptions), sibling plan 135 documents
  behavior in terms of them, and a pragma would warn on every internal use and force
  churn in the same release that changes `isFatal`. Revisit the pragma once the
  with-API has proven itself in a consumer (none registered today), recording the
  outcome here.
  Date: 2026-07-23

- Decision: The regression test observes close via the injectable close action
  (an `IORef`-flag wrapper around `closeConsumer`) on a consumer built against an
  unreachable broker, rather than via broker group membership.
  Rationale: `newConsumer` succeeds without a reachable broker (librdkafka connects
  lazily), so the full real code path — including hw-kafka-client's background loop
  and real `closeConsumer` — runs in a plain unit test. The repo's Redpanda harness
  (`process-compose.yaml`, `rpk container start`) exists but the test suite has no
  broker wiring or readiness plumbing, and adding it for one assertion is not
  proportionate; a manual broker-backed verification (group membership disappears at
  scope exit) is included in M3 as an optional step instead.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All edits happen in `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly` (cabal
project; package `hw-kafka-streamly` 0.2.0.0 in the `hw-kafka-streamly/`
subdirectory, plus the worked-examples package `hw-kafka-streamly-jitsurei`; GHC
9.12.2; resolved deps: `streamly-core` 0.3.0, `hw-kafka-client` 5.3.0, `tasty`
1.5.3). Tests: `cabal test hw-kafka-streamly-test` from the repo root (the Justfile
has build/format/broker recipes but no test recipe). Read-only references:
hw-kafka-client 5.3.0 at
`/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project/hw-kafka-client`,
streamly (0.4.0 corpus) at
`/Users/shinzui/Keikaku/hub/haskell/streamly-project/streamly`, and the streamly-core
0.3.0/0.3.1 Hackage tarballs (unpack with `cabal get streamly-core-0.3.0` if
needed), librdkafka 2.13.2 at
`/Users/shinzui/Keikaku/hub/librdkafka-project/librdkafka`.

ADR context: keiro's `docs/adr/` contains only
`0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job telemetry) — not
relevant. No relevant ADR exists. This plan contributes the deterministic-close row
to the fatal-observability-contract ADR that MasterPlan 23 names (see Validation).

Terms, in plain language. *Bracket*: acquire a resource, run something, release the
resource even on exceptions. *streamly `bracketIO`*: a stream combinator version of
that — but a stream is a value that is *pulled* by a downstream consumer, so if the
consumer stops pulling (abandonment), the combinator's cleanup has no execution
point left and streamly falls back to registering it as a GC finalizer
(`newIOFinalizer`). *Abandonment*: the downstream stops consuming a stream that
still has elements — `Stream.take n`, a fold that terminates early, or an exception
thrown downstream of the bracket. *Zombie consumer*: a `KafkaConsumer` whose
Haskell stream is gone but whose background poll loop still runs.

The current code, verified at
`hw-kafka-streamly/src/Kafka/Streamly/Stream.hs`:

- `kafkaStreamNoClose` (lines 104–118): unfoldrM around `pollMessage`; terminates
  only on a fatal error (per `isFatal`); never touches the consumer lifecycle.
- `kafkaStreamAutoClose` (lines 128–138): `Stream.bracketIO (pure consumer)
  (\c -> () <$ closeConsumer c) (\c -> kafkaStreamNoClose c timeout)` — lines
  133–137.
- `kafkaStream` (lines 158–172): same `bracketIO` shape with `newConsumer` in the
  acquire (throws the `KafkaError` via `throwIO` if creation fails) — lines
  164–172.
- The module's worked example (lines 21–41) pipes `kafkaStream` through
  `skipNonFatal` into `Stream.take 5` — the abandonment case, lines 38–41. Everyone
  who copies the example leaks a zombie for the lifetime of the process (or until
  an incidental major GC).

Why the zombie starves partitions (the full causal chain, each link verified):
abandonment ⇒ streamly defers `closeConsumer` to GC (streamly-core 0.3.0
`Exception.hs:400-409`) ⇒ hw-kafka-client's background loop keeps calling
`rd_kafka_consumer_poll` every 100 ms (`Consumer.hs:432-440`, started at
`newConsumer` line 159–160) ⇒ librdkafka counts each poll as application progress
(`rd_kafka_app_polled`, `src/rdkafka_int.h:1184-1246`, called from
`src/rdkafka.c:3413,3457`), so `max.poll.interval.ms` never fires, heartbeats
continue, the group coordinator sees a healthy member, and the zombie's partitions
are never rebalanced to a live consumer ⇒ meanwhile the rd_kafka handle's GC
finalizer (`RdKafka.chs:860-877`) cannot fire because the loop still references the
handle; only `closeConsumer` (`Consumer.hs:346-356`) stops the loop, and only GC
will call it. Process exit runs no finalizers at all (GHC does not run
ForeignPtr/IO finalizers at exit), so a short-lived program leaks the group member
until the broker's `session.timeout.ms` finally expires it — during which the
partitions are stalled.

What already works and must not regress: when the *stream itself* raises or ends
(fatal error from `isFatal`, exception inside polling), streamly's bracket runs the
cleanup promptly; `closeConsumer` performs librdkafka's leave-group and final
auto-commit. The fix targets only the abandonment/downstream paths, by moving the
close out of the stream into an enclosing IO scope.

The test suite today (`test/Main.hs`, `test/Kafka/Streamly/StreamTest.hs`,
`test/Kafka/Streamly/CombinatorsTest.hs`) is broker-free unit tests (tasty +
tasty-hunit; `-threaded` with `-N`). Sibling plan 135 adds `isFatal` cases to
`StreamTest.hs`; this plan adds a new module and leaves `StreamTest.hs` alone to
minimize merge friction.


## Plan of Work

### Milestone 1 — the scope-based API, the fixed example, and the warnings

Scope: new public functions plus docs. At the end, a user can consume any prefix
of a Kafka stream inside a scope and the consumer is provably closed when the
scope function returns; the module example demonstrates it; the legacy functions
warn.

In `hw-kafka-streamly/src/Kafka/Streamly/Stream.hs`, add an *internal* helper (not
exported) that both public functions and the test path share:

```haskell
-- | Internal: bracket a consumer around a stream-consuming continuation.
-- The close action is injectable so tests can observe it; production
-- callers always pass 'closeConsumer'.
withConsumerStreamVia ::
    IO KafkaConsumer ->                -- ^ acquire
    (KafkaConsumer -> IO ()) ->        -- ^ close (always runs, exactly once)
    Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a
withConsumerStreamVia acquire close timeout consume =
    Control.Exception.bracket acquire close $ \c ->
        consume (kafkaStreamNoClose c timeout)
```

and the two public entry points:

```haskell
withKafkaConsumerStream ::
    ConsumerProperties ->
    Subscription ->
    Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a
withKafkaConsumerStream props sub timeout =
    withConsumerStreamVia
        (newConsumer props sub >>= either throwIO pure)
        (void . closeConsumer)
        timeout

withKafkaConsumerStreamOn ::
    KafkaConsumer ->
    Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a
withKafkaConsumerStreamOn consumer =
    withConsumerStreamVia (pure consumer) (void . closeConsumer)
```

Notes for the implementer: `Control.Exception.bracket` and `void` need imports
(`Control.Exception (bracket, throwIO)` — `throwIO` is already imported; add
`Control.Monad (void)`). The continuation runs in `IO`, and the stream it receives
is `Stream IO ...`; this is deliberately monomorphic — the legacy entry points stay
polymorphic in `m`, but a scope function must pin the monad to run the bracket in
it, and `IO` is what every known consumer uses; if a concrete need for `MonadUnliftIO`
generality appears later, widen then (record in Decision Log). To make the close
observable-by-effect rather than silently discarded, follow `kafkaStreamAutoClose`'s
lead and drop the `Maybe KafkaError` from `closeConsumer` (`void`); do *not* rethrow
close errors — the scope may already be unwinding an exception.

Testability: export `withConsumerStreamVia` from the module under an
"Internal — exported for tests" haddock section (mirroring the convention sibling
plan 136 uses in kafka-effectful), since the test package cannot otherwise inject
the close observer. If you prefer to keep the public surface pristine, add a
`Kafka.Streamly.Stream.Internal` module instead; either satisfies M2 — record the
choice.

Haddocks, which carry half this plan's value:

- On both new functions: state the guarantee — "the consumer is closed when this
  function returns, regardless of how much of the stream the continuation
  consumed" — and show a `Stream.take`-based usage.
- On `kafkaStream` and `kafkaStreamAutoClose`: prepend a __Warning__ block: if the
  stream is partially consumed and abandoned (`Stream.take`, early-terminating
  folds, exceptions thrown downstream of this stream), the close is deferred to
  the garbage collector; until some GC runs, the consumer keeps its group
  membership and partition assignment alive from the background poll loop and its
  partitions are starved; process exit runs no finalizers. Point to
  `withKafkaConsumerStream`. Cite the streamly-core doc sentence ("Worst case …
  cleanup is deferred to GC") so the reader knows this is upstream-documented
  behavior, not a bug in this library.
- Update the module header's "Three tiers of resource management" (lines 10–19) to
  four tiers, with the with-functions listed first as the recommended default.
- Rewrite the module worked example (lines 21–41) to:

```haskell
main :: IO ()
main = do
    let props = brokersList ["localhost:9092"]
            <> groupId (ConsumerGroupId "example-group")
        sub  = topics ["example-topic"] <> offsetReset Earliest
    withKafkaConsumerStream props sub (Timeout 1000) $ \stream ->
        Stream.fold (Fold.drainMapM print) $
            Stream.take 5 $
                skipNonFatal stream
```

Also sweep the examples package: `grep -rn "kafkaStream" hw-kafka-streamly-jitsurei/`
and migrate any example that abandons a stream (e.g. take-style demos) to the new
API, leaving at least one deliberately-full-consumption example on the legacy API so
both remain exercised. Record in Progress which examples changed.

Acceptance: `cabal build all` clean; haddocks render (`cabal haddock
hw-kafka-streamly` builds without warnings about the new sections); example
compiles as part of the jitsurei package build.

### Milestone 2 — the zombie regression test

Scope: a new test module proving the guarantee and demonstrating the old failure.
At the end, the suite contains a test that fails when the with-function is
implemented with stream-level `bracketIO` and passes with the scope-level bracket.

Add `test/Kafka/Streamly/WithStreamTest.hs` (wire into `test/Main.hs` and
`other-modules` of the test stanza in `hw-kafka-streamly.cabal`):

Test 1 — *close runs before the scope returns, under abandonment* (the KSC-7
regression). Build a real consumer against an unreachable broker (no Docker:
librdkafka creation succeeds without connecting):

```haskell
mkProps :: ConsumerProperties
mkProps = brokersList [BrokerAddress "localhost:1"]
        <> groupId (ConsumerGroupId "with-stream-test")

test_closesOnAbandonment :: Assertion
test_closesOnAbandonment = do
    closed <- newIORef (0 :: Int)
    consumerE <- newConsumer mkProps (topics ["with-stream-test-topic"])
    consumer <- either (assertFailure . show) pure consumerE
    _ <- withConsumerStreamVia
            (pure consumer)
            (\c -> modifyIORef' closed (+ 1) <* closeConsumer c)
            (Timeout 50)
            (\stream -> Stream.fold Fold.toList (Stream.take 2 stream))
    n <- readIORef closed
    n @?= 1
```

The stream yields `Left (KafkaResponseError RdKafkaRespErrTimedOut)` elements
(polls time out against the unreachable broker), so `Stream.take 2` returns
quickly; the assertion is that the close action ran exactly once by the time
`withConsumerStreamVia` returned — no GC involved (do *not* call
`System.Mem.performGC` anywhere in this test; its absence is the point). Keep the
poll timeout small (50 ms) so the test completes in well under a second.

Test 2 — *close runs exactly once when the continuation throws*: same setup, the
continuation reads one element then `throwIO` a sentinel exception; assert the
exception propagates and the flag is 1.

Test 3 — *the old shape demonstrably leaks* (documentation-grade evidence, and the
"fails before/passes after" half of the acceptance): implement a local copy of the
old pattern inside the test —

```haskell
leakyTake :: KafkaConsumer -> IORef Int -> IO [Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))]
leakyTake consumer closed =
    Stream.fold Fold.toList $
        Stream.take 2 $
            Stream.bracketIO
                (pure consumer)
                (\c -> modifyIORef' closed (+ 1) <* closeConsumer c)
                (\c -> kafkaStreamNoClose c (Timeout 50))
```

and assert that immediately after `leakyTake` returns the flag is still 0 — the
cleanup did not run at abandonment. (Close the consumer at the end of the test
manually to avoid leaking into later tests.) This test pins the *reason* the new
API exists; a comment must link KSC-7 and MasterPlan 23. If a streamly upgrade ever
makes this assertion fail — i.e. bracketIO becomes prompt under abandonment — that
is a welcome surprise: record it in this plan and reconsider the warnings.

Note on test parallelism: the suite runs with `-N`; each test creates its own
consumer with its own group id string, and none needs a broker, so there is no
cross-test interference. `newConsumer` in Async mode starts a background loop per
consumer — ensure every code path (including assertion failures) closes its
consumer so the suite process does not accumulate loops; use `finally` around test
bodies where the consumer is created manually.

Acceptance: `cabal test hw-kafka-streamly-test` green in ~seconds; temporarily
reimplementing `withConsumerStreamVia` with `Stream.bracketIO` makes Test 1 fail
(flag 0, not 1) — perform this experiment once, capture the failing output into
Surprises & Discoveries, and revert.

### Milestone 3 — changelog, release posture, optional broker verification

Scope: bookkeeping that makes the change consumable. Update
`hw-kafka-streamly/CHANGELOG.md` under `## Unreleased`: added
`withKafkaConsumerStream`/`withKafkaConsumerStreamOn` (+ the internal helper if
exported), rewrote the worked example, documented GC-deferral on the legacy entry
points (Added/Changed/Docs subsections per Keep a Changelog). This is an additive
API change: minor PVP bump at least; coordinate with sibling plan 135, which
touches the same package — one release carries both (whichever plan lands second
cuts it; if this plan is second, verify 135's `isFatal` arms and StreamTest
changes are present before tagging).

Optional broker-backed verification (manual, evidence-grade): with Docker
available, `just process-up` and `just create-topic` in the repo root start
Redpanda on `localhost:9092` with `jitsurei-topic`. Run a scratch program that
uses `withKafkaConsumerStream` with `groupId "zombie-check"`, consumes
`Stream.take 1`, and then sleeps 30 s before exiting. In another shell:
`rpk group describe zombie-check` — the member must disappear within a second of
the take completing (scope exit closed the consumer), *not* after the session
timeout. Repeat with the legacy `kafkaStream`+`take` shape and observe the member
linger. Capture both transcripts into Surprises & Discoveries. Tear down with
`just process-down`.

Acceptance: changelog entry present; release coordination noted in both plans'
Progress sections; optional transcripts captured or the step marked skipped with
reason.


## Concrete Steps

Working directory for all commands: `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly`.

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly
cabal build all
cabal test hw-kafka-streamly-test
```

Expected test output shape after M2 (counts vary; zero failures is the criterion):

```text
Stream
  isFatal: ...        OK
  ...
WithStream
  closes on abandonment:        OK
  closes once on continuation exception: OK
  legacy bracketIO defers close under take: OK
All NN tests passed
Test suite hw-kafka-streamly-test: PASS
```

The one-time red-state experiment for Test 1 (do once, then revert):

```bash
# in src/Kafka/Streamly/Stream.hs, temporarily reimplement withConsumerStreamVia
# with Stream.bracketIO in the continuation's stream, then:
cabal test hw-kafka-streamly-test 2>&1 | grep -A4 "closes on abandonment"
# expected: FAIL with "expected: 1 / but got: 0"; paste into Surprises & Discoveries
git checkout -- hw-kafka-streamly/src/Kafka/Streamly/Stream.hs   # revert (or re-apply the good version)
```

Haddock check:

```bash
cabal haddock hw-kafka-streamly
```

Optional broker verification: see Milestone 3 (uses `just process-up`,
`just create-topic`, `rpk group describe`, `just process-down`).


## Validation and Acceptance

Complete when:

1. `cabal test hw-kafka-streamly-test` passes with the three `WithStream` cases,
   and the red-state transcript (Test 1 failing under a bracketIO-based
   implementation) is recorded in this plan.
2. The module worked example uses `withKafkaConsumerStream` with `Stream.take` —
   i.e. the example that used to leak now provably cannot — and the jitsurei sweep
   is recorded in Progress.
3. `kafkaStream` and `kafkaStreamAutoClose` haddocks carry the GC-deferral
   warning with the pointer to the new API; `cabal haddock` succeeds.
4. CHANGELOG updated; release coordination with plan 135 recorded (one release,
   second-lander cuts it).
5. ADR distillation: contribute the deterministic-close row (scope-based close is
   the supported pattern; legacy entry points are GC-deferred under abandonment;
   process exit runs no finalizers) to the fatal-observability-contract ADR named
   by MasterPlan 23; whichever of plans 135/136/137 finishes last completes that
   ADR in keiro's `docs/adr/`.

Behavioral acceptance in one sentence: taking five records from a managed Kafka
stream closes the consumer the moment the scope exits — observable as the close
flag in the regression test and, against a real broker, as the group member
vanishing immediately instead of lingering as a partition-starving zombie.


## Idempotence and Recovery

Everything is additive and re-runnable: the new functions do not alter the legacy
ones, tests create disposable consumers, and the red-state experiment is a
temporary local edit reverted via git. If the unreachable-broker consumer behaves
differently on some platform (e.g. `newConsumer` fails fast), substitute
`localhost:<unused-port>` or a non-routable address (`203.0.113.1:9092`) and record
it; the tests only require that creation succeeds and polls time out. If exporting
the internal helper is later regretted, moving it to an `.Internal` module is a
minor PVP bump with no registered dependents to break. The optional broker steps
are safely re-runnable (`rpk container purge` via `just process-down` resets
state).


## Interfaces and Dependencies

End state of `Kafka.Streamly.Stream`'s public surface (additions only):

```haskell
withKafkaConsumerStream ::
    ConsumerProperties -> Subscription -> Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a

withKafkaConsumerStreamOn ::
    KafkaConsumer -> Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a

-- Internal — exported for tests (or in Kafka.Streamly.Stream.Internal):
withConsumerStreamVia ::
    IO KafkaConsumer -> (KafkaConsumer -> IO ()) -> Timeout ->
    (Stream IO (Either KafkaError (ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString))) -> IO a) ->
    IO a
```

`kafkaStream`, `kafkaStreamAutoClose`, `kafkaStreamNoClose`, the predicates, and
the filters are unchanged in type and runtime behavior (docs only). Dependencies:
no new packages — `base`'s `Control.Exception.bracket`, existing `streamly-core`
(`>=0.3 && <0.5`, resolved 0.3.0; the new code uses nothing version-sensitive) and
`hw-kafka-client` (`>=5.3 && <6`, resolved 5.3.0 — or plan 135's fork pin once
this repo's `cabal.project` carries it; this plan's tests do not depend on the
pin). Test stanza gains no new dependencies (`tasty`, `tasty-hunit`,
`streamly-core`, `hw-kafka-client` already present; `Data.IORef` is base).
Coordination: sibling plan 135 edits `Stream.hs` (isFatal, lines 183–204 region)
and `StreamTest.hs`; this plan edits `Stream.hs` (module header, examples, new
functions at the end of the Streams section) and adds `WithStreamTest.hs` — merge
order is irrelevant, conflicts are textual-only in the module header/export list.
