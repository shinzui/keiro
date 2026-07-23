---
id: 135
slug: surface-librdkafka-fatal-errors-through-the-consumer-stack
title: "Surface librdkafka fatal errors through the consumer stack"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md"
---

# Surface librdkafka fatal errors through the consumer stack

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a Kafka consumer suffers a *fatal* error — the canonical example is a static group
member being "fenced" because a second consumer started with the same
`group.instance.id` — librdkafka permanently halts all group activity for that client.
Today, no Haskell layer of our consumer stack can observe that this happened. In the
default asynchronous callback-poll mode of `hw-kafka-client`, the binding's background
loop reads the error off librdkafka's consumer queue and throws it away (leaking the C
message object in the process), so the application polls an empty side queue forever:
a silent, permanent stall that also defeats librdkafka's own `max.poll.interval.ms`
watchdog. In the synchronous mode the fatal error does reach the application in-band,
but `hw-kafka-streamly`'s `isFatal` predicate misclassifies it as non-fatal, so the
recommended `skipNonFatal` filter silently drops the one signal that the consumer is
dead, and the polling stream retries forever.

After this plan is implemented: (1) a patched fork of `hw-kafka-client` makes
consumer-queue errors — at minimum the fatal one — visible to the application in Async
mode, destroys every message the background loop consumes instead of leaking it, and is
pinned via a `cabal.project` `source-repository-package` stanza with an upstream PR
filed; (2) `hw-kafka-streamly` classifies `RdKafkaRespErrFatal` (and SASL
authentication failure) as fatal, so a Sync-mode or pinned-Async-mode stream terminates
loudly on a fenced consumer instead of spinning. You can see it working by running the
updated unit tests (which pin the new taxonomy and fail against the old code) and, with
a local Redpanda broker, by starting two consumers with the same `group.instance.id`
and watching the first one's stream terminate with `Left (KafkaResponseError
RdKafkaRespErrFatal)` instead of hanging.

This plan is EP-1 of MasterPlan 23
(`docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md`).
Sibling plans: `docs/plans/136-classify-poll-and-commit-errors-and-fix-traced-context-hygiene.md`
(kafka-effectful interpreter taxonomy; soft-depends on this plan's corrected `isFatal`
table) and `docs/plans/137-guarantee-deterministic-consumer-close-in-hw-kafka-streamly.md`
(deterministic close; shares the `hw-kafka-streamly` release with this plan).


## Progress

- [ ] M1: Fork `haskell-works/hw-kafka-client`, branch, and implement the Async-mode fix
      (fatal sink + message destruction in `pollConsumerEvents'`, `rd_kafka_fatal_error`
      binding, sink check in `pollMessage`/`pollMessageBatch`).
- [ ] M1: Fork builds and its unit test suite passes; upstream PR text written and PR
      opened; exact pin commit recorded in this plan.
- [ ] M2: `isFatal` in `hw-kafka-streamly` gains `RdKafkaRespErrFatal` and
      `RdKafkaRespErrSaslAuthenticationFailed` arms; `StreamTest.hs` taxonomy pins
      updated (20 fatal + 3 non-fatal); tests pass.
- [ ] M3: Fork pin applied to `hw-kafka-streamly/cabal.project`; pin stanzas for
      `kafka-effectful` and `shibuya-kafka-adapter` documented here for adoption on
      their next build; CHANGELOG entries written.
- [ ] Optional demo: fenced-consumer end-to-end repro against local Redpanda executed
      and transcript captured here.


## Surprises & Discoveries

Findings from plan-authoring verification (2026-07-23), all re-checked against the
sources on disk; treat these as the evidence base for the design below.

- The leak-fix pattern already exists upstream, unused on the broken path:
  `src/Kafka/Internal/RdKafka.chs` lines 612–616 define `pollRdKafkaConsumer`, which
  wraps the raw `rdKafkaConsumerPoll` and attaches the `rd_kafka_message_destroy`
  finalizer (`rdKafkaMessageDestroyF`, bound at lines 766–767). The background loop
  calls the raw, finalizer-less `rdKafkaConsumerPoll` instead.
- The voiding path also runs on the application thread: `pollMessageBatch`
  (`src/Kafka/Consumer.hs:188-193`) calls `pollConsumerEvents c Nothing` (line 189)
  before draining the side queue, which reaches the same `void $ rdKafkaConsumerPoll`
  at lines 454–457. So every batch poll can also discard (and leak) a consumer-queue
  message, including the fatal one.
- The hypothesis that `rd_kafka_queue_poll` on the consumer queue would avoid resetting
  the `max.poll.interval.ms` timer is refuted. librdkafka marks the consumer group
  queue with `RD_KAFKA_Q_F_CONSUMER`, and the flag's own comment
  (`src/rdkafka_queue.c:134-138` in the corpus at
  `/Users/shinzui/Keikaku/hub/librdkafka-project/librdkafka`) states: "Setting this
  flag indicates that polling this queue is equivalent to calling consumer poll, and
  will reset the max.poll.interval.ms timer." Every user-facing poll of a
  consumer-flagged queue (`rd_kafka_consumer_poll`, `rd_kafka_queue_poll`,
  `rd_kafka_consume_queue`) goes through `rd_kafka_app_poll_start` /
  `rd_kafka_app_polled` (`src/rdkafka_int.h:1184-1246`; call sites `src/rdkafka.c:3413`
  and `:3457`, `src/rdkafka_queue.c:421,595,763` etc.). Consequence: the watchdog reset
  cannot be avoided while the background loop calls any consumer-poll variant — see
  Decision Log for how this plan handles it.
- `hw-kafka-client` has no binding for `rd_kafka_fatal_error` (grep of
  `src/Kafka/Internal/RdKafka.chs` finds none) and none for
  `rd_kafka_queue_get_consumer` (needed only by the rejected alternative design).
- One citation in the review had a path imprecision: the "NoOffset is not an error"
  documentation lives at `src/Kafka/Consumer/Callbacks.hs:37-39` (the `Consumer`
  subdirectory), not `src/Kafka/Callbacks.hs`. Content verified as cited. (That finding
  belongs to sibling plan 136; recorded here because the verification happened while
  reading this repo.)


## Decision Log

- Decision: Fix fatal observability upstream in a `hw-kafka-client` fork (pin + PR),
  not with an application-level no-progress watchdog.
  Rationale: Inherited from MasterPlan 23's Decision Log. Verification proved no
  downstream layer can observe the signal in Async mode, so any workaround would be a
  heuristic timer that misfires on legitimately idle topics. The cohort has fork-pin
  precedent (`shinzui/hasql-migration` pinned in
  `/Users/shinzui/Keikaku/bokuno/danwa/cabal.project:86-89`; codd pinned in this repo's
  `cabal.project`).
  Date: 2026-07-23

- Decision: Implement the minimal "inspect, record, destroy" design in the background
  loop (Route A below) rather than re-architecting Async mode to stop resetting the
  poll watchdog (Route B).
  Rationale: Route A preserves all existing hw-kafka-client semantics (callback
  threading, rebalance timing) and is a small, reviewable upstream patch. Route B —
  polling the main queue with `rd_kafka_poll` and forwarding the consumer queue to the
  app's side queue — would restore `max.poll.interval.ms` as a real watchdog but moves
  rebalance-callback execution onto the application polling thread and requires a new
  `rd_kafka_queue_get_consumer` binding; that is a semantic change upstream may reject
  wholesale. The watchdog-reset defect therefore remains in Async mode and is
  *documented* (in the fork's haddocks and the PR text) rather than fixed; Route B is
  offered in the PR text as follow-up work. Verified basis: the `RD_KAFKA_Q_F_CONSUMER`
  analysis in Surprises & Discoveries shows no consumer-poll variant avoids the timer.
  Date: 2026-07-23

- Decision: Surface consumer-queue errors to the application via a per-consumer "fatal
  sink" field (an `IORef` holding the first fatal `KafkaError`) checked by
  `pollMessage` and `pollMessageBatch`, rather than forwarding raw rkmessages onto the
  Async side queue.
  Rationale: An rkmessage cannot be re-enqueued onto another librdkafka queue from the
  binding (no such C API); copying it into a Haskell value and injecting it into the
  side-queue stream would require inventing an in-band channel that `pollMessage`'s
  return type already provides. The sink makes the fatal appear exactly where Sync mode
  already delivers it: as `Left (KafkaResponseError RdKafkaRespErrFatal)` from the next
  poll. Non-fatal consumer-queue errors observed by the loop are handed to the
  configured `error_cb` if one is set (preserving "errors reach the error callback"
  expectations) and otherwise dropped after destruction — identical visibility to
  today, minus the leak.
  Date: 2026-07-23

- Decision: `isFatal` gains two new arms: `KafkaResponseError RdKafkaRespErrFatal` and
  `KafkaResponseError RdKafkaRespErrSaslAuthenticationFailed`.
  Rationale: `RdKafkaRespErrFatal` (from `RD_KAFKA_RESP_ERR__FATAL` = -150) is the
  generic wrapper librdkafka uses when propagating any raised fatal error to
  `consumer_poll()`; missing it is the KSC-2 defect. `SaslAuthenticationFailed` is the
  broker-side SASL rejection; like the already-fatal `Authentication` (transport-level)
  arm, retrying it in a tight poll loop is never useful and can lock accounts. Both
  constructors verified present in the binding's generated enum. The existing 18 arms
  are kept unchanged.
  Date: 2026-07-23

- Decision: The fork is a clean fork of `haskell-works/hw-kafka-client` on GitHub
  (`shinzui/hw-kafka-client`), branched from the `v5.3.0` release tag (falling back to
  the latest master if the tag does not build with our toolchain), not the local corpus
  repo.
  Rationale: The local corpus at
  `/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project` is a project wrapper
  (its git origin is `shinzui/hw-kafka-client-project`, and it carries corpus-only
  commits such as mori doc updates); an upstream PR must come from a fork of the real
  upstream repository, and the pin must point at a repo whose layout cabal understands
  (the package lives in the `hw-kafka-client/` subdirectory of the corpus project,
  which would force a `subdir:` stanza and tie the pin to a non-canonical repo).
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

You are working across three code locations. Nothing in this plan edits the keiro
repository except this document.

1. `hw-kafka-client` — the Haskell binding to librdkafka (the C client library for
   Apache Kafka). A read-only reference copy is at
   `/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project/hw-kafka-client`
   (version 5.3.0, the version all our repos resolve today). Milestone 1 creates a
   *new working clone* of the upstream GitHub repository to carry the fix.
2. `hw-kafka-streamly` — our streamly integration, at
   `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly` (cabal project with two packages:
   `hw-kafka-streamly` and `hw-kafka-streamly-jitsurei`, the worked-examples package).
   Milestones 2 and 3 edit this repo.
3. `librdkafka` — the C library itself, read-only reference at
   `/Users/shinzui/Keikaku/hub/librdkafka-project/librdkafka` (version 2.13.2,
   `RD_KAFKA_VERSION 0x020d02ff`). You never edit it; you read it to confirm delivery
   mechanics. Note our reference copy is newer than what a distro may link; the cited
   mechanics (consumer-error delivery, app-poll timer) are stable across 1.6+.

ADR context: keiro's `docs/adr/` contains only
`0001-keiro-pgmq-job-processing-telemetry-contract.md`, which concerns pgmq job
telemetry and is not relevant to this plan. No relevant ADR exists. MasterPlan 23
names a candidate ADR (the consumer fatal-observability contract) to be written at
completion — see the ADR distillation step in Validation and Acceptance.

Terms used throughout, in plain language:

- *rkmessage*: librdkafka's C struct (`rd_kafka_message_t`) representing either a
  fetched record or an error; it must be freed with `rd_kafka_message_destroy` or it
  leaks C heap memory.
- *consumer queue*: the librdkafka queue attached to the consumer group handle
  (`rkcg_q` in the C source). Rebalance events, offset-commit results, consumer errors
  and (until redirected) fetched messages arrive here. `rd_kafka_consumer_poll` reads
  this queue.
- *callback-poll mode*: `hw-kafka-client`'s `CallbackPollMode` — `CallbackPollModeSync`
  means the application's own `pollMessage` calls serve librdkafka callbacks;
  `CallbackPollModeAsync` (the default, set in
  `src/Kafka/Consumer/ConsumerProperties.hs:70`) means a background Haskell thread
  serves them.
- *c2hs*: the preprocessor that turns `src/Kafka/Internal/RdKafka.chs` into a generated
  `RdKafka.hs`; `{#fun ...#}` blocks become foreign-call wrappers. The generated
  marshalling for `rd_kafka_consumer_poll` uses `newForeignPtr_` — a foreign pointer
  with *no* finalizer, so dropping it leaks the rkmessage.
- *fenced*: with static group membership (`group.instance.id`), if a second consumer
  joins with the same instance id, the broker "fences" the first; librdkafka raises a
  fatal error for it.

How the default (Async) mode actually works, verified against the 5.3.0 source — this
is the mental model everything below relies on:

`newConsumer` (`src/Kafka/Consumer.hs:115-165`) creates the client, and in Async mode
creates a *separate side queue* via `rdKafkaQueueNew`, storing it in the
`kcfgMessagesQueue` field of `KafkaConf` (lines 137–139; `KafkaConf` is defined in
`src/Kafka/Internal/Setup.hs:57-65`). It installs a rebalance callback
(`src/Kafka/Consumer/Callbacks.hs:57-95`) which, on partition assignment, *forwards
each assigned partition's fetch queue to the side queue* (`redirectPartitionQueue`,
lines 50–55, with a pause/redirect/resume dance quoted from librdkafka's author at
lines 78–81). It calls `rd_kafka_poll_set_consumer` (via `redirectCallbacksPoll`, line
141), which forwards the *main* queue (log/stats/error callbacks) into the consumer
queue. Finally it starts the background loop (`runConsumerLoop`, lines 432–440) at line
159–160 with a 100 ms poll timeout.

So in steady state: fetched records flow to the side queue, which the application
drains via `pollMessage` (`src/Kafka/Consumer.hs:167-176`: Async mode takes the
`Just q` branch, `rdKafkaConsumeQueue`). Everything else — rebalance ops, offset-commit
results, error/log/stats ops, and **consumer errors** — flows to the consumer queue,
which only the background loop drains: `pollConsumerEvents'` (lines 454–457) is
literally `void $ rdKafkaConsumerPoll (getRdKafka k) tm`. Callback-type ops are served
inside librdkafka's `rd_kafka_poll_cb` during that call (that part works). But two op
types are *returned as rkmessages* instead of being served as callbacks, and `void`
discards them: fetched records that raced onto the consumer queue before a partition
redirect, and `RD_KAFKA_OP_CONSUMER_ERR` — every consumer error, including the fatal.

Why the fatal can *only* appear there, verified in librdkafka 2.13.2:

- When a fatal error is raised, `rd_kafka_set_fatal_error` routes it for consumers to
  `rd_kafka_consumer_err(rk->rk_cgrp->rkcg_q, ..., RD_KAFKA_RESP_ERR__FATAL, ...)` —
  the consumer queue — with the comment "for the high-level consumer we propagate the
  error as a consumer error so it is returned from consumer_poll()"
  (`src/rdkafka.c:895-907`). Only non-consumer clients get the `error_cb` route.
- `rd_kafka_consumer_err` builds an `RD_KAFKA_OP_CONSUMER_ERR` op
  (`src/rdkafka_op.c:567-587`).
- In the poll callback dispatcher, `RD_KAFKA_OP_CONSUMER_ERR` under
  `RD_KAFKA_Q_CB_RETURN` (the consumer-poll path) returns `RD_KAFKA_OP_RES_PASS` —
  "return as message_t to application" — *before* falling through to the `error_cb`
  branch (`src/rdkafka.c:4150-4165`). An installed `error_cb` therefore can never see a
  consumer fatal.
- The partition-level `rd_kafka_consumer_err` call sites
  (`src/rdkafka_partition.c:1301,1507,2189`) target per-partition fetch queues and
  carry only non-fatal conditions; the fatal is exclusively on the consumer queue.
- Post-fatal, librdkafka halts all group activity: the join state machine returns
  immediately (`src/rdkafka_cgrp.c:6024-6025`) and subscribes are treated as
  unsubscribes (`src/rdkafka_cgrp.c:6280-6285`). There is no recovery except
  destroying the client.

Two aggravating defects ride the same loop. First, the memory leak: the c2hs-generated
`rdKafkaConsumerPoll` (generated `RdKafka.hs:1832-1838`, from `RdKafka.chs:609-610`)
marshals the returned rkmessage with `newForeignPtr_` — no finalizer — and the only
place that destroys rkmessages is `fromMessagePtr`
(`src/Kafka/Consumer/Convert.hs:155-163`, destroy at line 163), which the loop never
calls; every voided message leaks. Second, the watchdog reset: every
`rd_kafka_consumer_poll` call invokes `rd_kafka_app_polled` on all exit paths
(`src/rdkafka.c:3413,3430,3442,3457`; implementation `src/rdkafka_int.h:1184-1246`),
stamping "the application polled now" — so the loop's 100 ms cadence permanently
defeats `max.poll.interval.ms` as a liveness check regardless of application progress.

The Sync-mode half (KSC-2): in `CallbackPollModeSync`, `pollMessage` polls the consumer
queue directly and `fromMessagePtr` converts the fatal op to
`Left (KafkaResponseError RdKafkaRespErrFatal)` in-band (the constructor exists:
generated `RdKafka.hs:148`, from `RD_KAFKA_RESP_ERR__FATAL` = -150). But
`hw-kafka-streamly`'s `isFatal`
(`hw-kafka-streamly/src/Kafka/Streamly/Stream.hs:183-204`) enumerates 18 fatal arms
and has no `RdKafkaRespErrFatal` arm; the wildcard at line 203 returns `False`. So
`kafkaStreamNoClose` (lines 109–118; the non-fatal branch at 116–117) keeps polling a
dead consumer forever, and the module's recommended `skipNonFatal` filter (lines
241–246) silently *drops* the fatal from the stream. The test file
`hw-kafka-streamly/test/Kafka/Streamly/StreamTest.hs` pins this wrong taxonomy: 18
entries in `fatalErrors` (lines 32–52) and 3 in `nonFatalErrors` (lines 54–59).

Also relevant: `kafkaStreamNoClose` calls `pollMessage` directly on a concrete
`KafkaConsumer` — the poll action is *not* injectable, so a fenced-consumer simulation
cannot be constructed at the stream level without a real consumer handle. Milestone 2
therefore pins the corrected `isFatal` with unit tests (which is where the defect
lives) and the optional broker demo provides the end-to-end evidence.

Dependents (from `mori registry dependents`): no registered project depends on
`shinzui/hw-kafka-streamly`, so the M2 taxonomy change breaks no downstream repo.
`shinzui/kafka-effectful` is depended on by `keiro-runtime-jitsurei`,
`shibuya-kafka-adapter`, and `shikigami` — that matters for M3's pin propagation notes
(and for sibling plan 136), not for any code here.


## Plan of Work

### Milestone 1 — the upstream fix, in a fork of hw-kafka-client

Scope: make Async mode destroy every consumer-queue message it consumes and record
consumer errors so the application observes fatals; bind `rd_kafka_fatal_error`; leave
all other behavior identical. At the end of this milestone a fork exists on GitHub
with a branch whose HEAD commit builds, passes the package's unit tests, and is the
commit the pin recipe names; an upstream PR is open.

Create the working clone (do not reuse the corpus checkout):

```bash
cd /Users/shinzui/Keikaku/bokuno
gh repo fork haskell-works/hw-kafka-client --clone --fork-name hw-kafka-client
cd hw-kafka-client
git checkout -b fix/async-consumer-fatal-observability v5.3.0
```

If the `v5.3.0` tag does not exist under that exact name, list tags with `git tag -l`
and use the tag whose cabal version is 5.3.0; if master has diverged only by
non-consumer changes, branching from master is acceptable — record which base you used
in this plan's Decision Log.

The edits, all inside the clone:

First, in `src/Kafka/Internal/RdKafka.chs`, add a binding for `rd_kafka_fatal_error`
next to the other `rd_kafka_*` administrative bindings (the C prototype is
`rd_kafka_resp_err_t rd_kafka_fatal_error(rd_kafka_t *rk, char *errstr, size_t
errstr_size)` — it fills the buffer with a human-readable description of the
previously raised fatal error and returns its original error code, or
`RD_KAFKA_RESP_ERR_NO_ERROR` if no fatal has been raised). Model the marshalling on
the existing `newRdKafkaT` buffer usage:

```haskell
rdKafkaFatalError :: RdKafkaTPtr -> IO (RdKafkaRespErrT, Text)
rdKafkaFatalError k =
    allocaBytes nErrorBytes $ \charPtr -> do
        code <- withForeignPtr k $ \kPtr ->
            {#call rd_kafka_fatal_error#} kPtr charPtr (fromIntegral nErrorBytes)
        err <- peekCText charPtr
        pure (cIntToEnum code, err)
```

Second, in `src/Kafka/Internal/Setup.hs`, add a fourth field to `KafkaConf` (currently
`kcfgKafkaConfPtr`, `kcfgMessagesQueue`, `kcfgCallbackPollStatus`, lines 57–65):
`kcfgFatalError :: IORef (Maybe KafkaError)` — the *fatal sink*, set once by whichever
thread first observes a consumer error whose code is `RdKafkaRespErrFatal`, and read
by the polling API. Initialize it to `Nothing` in `kafkaConf` (same module) and update
every construction/pattern site the compiler flags (they are all in
`Kafka.Internal.Setup`, `Kafka.Consumer`, and the callback modules; let GHC's
exhaustiveness errors drive you). Avoid importing `Kafka.Types` circularly: if
`KafkaError` is not importable there, store `RdKafkaRespErrT` plus the error string
(`IORef (Maybe (RdKafkaRespErrT, Text))`) and wrap it into `KafkaError` at the read
site in `Kafka.Consumer` — choose whichever compiles cleanly and record the choice.

Third, in `src/Kafka/Consumer.hs`, replace `pollConsumerEvents'` (lines 454–457). The
new behavior, in prose: poll the consumer queue with the same timeout as before; if
the returned pointer is null (timeout), do nothing; otherwise read the rkmessage's
`err` field. If the code is `RdKafkaRespErrNoError`, this is a fetched record that
raced the partition redirect — destroy it (this preserves current behavior, which
dropped such records, but stops the leak; note this in the haddock). If the code is
`RdKafkaRespErrFatal`, resolve the underlying cause via `rdKafkaFatalError` and write
`Just (KafkaResponseError <original code>)` (or the wrapped pair) into the fatal sink
with `atomicModifyIORef'` keeping the *first* value if already set. For any other
error code, invoke the configured error callback if one was installed (the conf's
error callback is already dispatched by librdkafka for `OP_ERR`; for these
`OP_CONSUMER_ERR` returns nothing is dispatched, so simply destroy it and continue —
matching today's visibility) — then destroy the message. Destruction: either call
`rdKafkaMessageDestroy` explicitly on the raw pointer before returning, or route the
whole read through the existing finalizer-attaching `pollRdKafkaConsumer`
(`RdKafka.chs:612-616`) and let the finalizer collect it; explicit destruction is
preferred because it is prompt and this loop runs every 100 ms. A sketch:

```haskell
pollConsumerEvents' :: KafkaConsumer -> Maybe Timeout -> IO ()
pollConsumerEvents' k timeout = do
    let (Timeout tm) = fromMaybe (Timeout 0) timeout
    msgPtr <- rdKafkaConsumerPoll (getRdKafka k) tm
    withForeignPtr msgPtr $ \realPtr ->
        unless (realPtr == nullPtr) $ do
            s <- peek realPtr
            case err'RdKafkaMessageT s of
                RdKafkaRespErrNoError -> pure ()   -- raced fetch; drop as before
                RdKafkaRespErrFatal   -> do
                    (origErr, _detail) <- rdKafkaFatalError (getRdKafka k)
                    let ref = kcfgFatalError (getKafkaConf k)
                    atomicModifyIORef' ref $ \old ->
                        (old <|> Just (KafkaResponseError origErr), ())
                _ -> pure ()                        -- non-fatal consumer error; visibility unchanged
            rdKafkaMessageDestroy realPtr
```

Fourth, make the sink observable: at the top of `pollMessage`
(`src/Kafka/Consumer.hs:167-176`) and `pollMessageBatch` (lines 183–193), read the
sink first; if it holds `Just e`, return `Left e` (for the batch: `[Left e]`)
without polling. Do *not* clear the sink — a fatal is permanent, and every subsequent
poll must keep reporting it. Extend both functions' haddocks: in Async mode a fatal
consumer error is now reported in-band as `Left (KafkaResponseError <original
fatal cause>)`; before this change it was silently unobservable. Also update
`pollConsumerEvents`'s haddock (lines 335–341) to document that consumed messages are
destroyed and fatals recorded. Note the returned error is the *original cause* code
(for example the fenced-member code) as resolved by `rd_kafka_fatal_error`, not the
generic `RdKafkaRespErrFatal` wrapper Sync mode yields — callers should treat both
via `isFatal`, which M2 makes true. If during implementation you find resolving the
original code awkward at the read site, returning `RdKafkaRespErrFatal` itself is an
acceptable simplification — record whichever you ship in the Decision Log, because
sibling plan 136's classifier notes depend on it.

Fifth, the watchdog documentation: add to the `CallbackPollModeAsync` haddock in
`src/Kafka/Consumer/ConsumerProperties.hs` (around line 70) a warning that in Async
mode the background loop polls the consumer queue every 100 ms, and librdkafka counts
any consumer-queue poll as application progress, so `max.poll.interval.ms` cannot
detect a stuck application in this mode (evidence: `RD_KAFKA_Q_F_CONSUMER` comment,
`rdkafka_queue.c:134-138`); applications needing that watchdog must use
`CallbackPollModeSync`. This is documentation only — see Decision Log for why Route B
(actually restoring the watchdog) is out of scope.

Add a CHANGELOG entry, run the build and unit tests (Concrete Steps below), commit
(conventional message, e.g. `fix(consumer): surface consumer-queue fatal errors and
destroy polled messages in async callback mode`), push the branch, and open the PR
against `haskell-works/hw-kafka-client` with `gh pr create`. The PR body should
contain, in order: the delivery-mechanics evidence (the four librdkafka citations from
Context and Orientation), the leak explanation, the fix description, the watchdog
caveat with Route B sketched as possible follow-up, and a note that messages with
`err == 0` on the consumer queue were already being dropped before this patch (the
patch only stops leaking them). Record the PR URL and the branch HEAD commit hash in
this plan the moment they exist — the pin recipe in M3 needs the hash.

Acceptance for M1: `cabal build hw-kafka-client` and `cabal test
hw-kafka-client-test` succeed in the fork; reading the diff shows no call site that
still voids `rdKafkaConsumerPoll`'s result; the PR is open.

### Milestone 2 — hw-kafka-streamly classifies the fatal as fatal

Scope: two new `isFatal` arms and the matching test-pin update. At the end, the
taxonomy tests fail on the old code and pass on the new, and a fenced consumer in
Sync mode (or Async mode under the M1 pin) terminates the stream.

In `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/hw-kafka-streamly/src/Kafka/Streamly/Stream.hs`,
insert two arms into `isFatal` before the wildcard at line 203:

```haskell
    KafkaResponseError RdKafkaRespErrFatal -> True
    KafkaResponseError RdKafkaRespErrSaslAuthenticationFailed -> True
```

Extend the function's haddock (lines 178–182) to name the fenced-static-member
scenario: after librdkafka raises a fatal error the consumer's group activity is
permanently halted, so `RdKafkaRespErrFatal` must terminate the stream; cite that the
generic code arrives in-band from `pollMessage` in Sync mode and, once the fork pin
from this plan's M1 is adopted, in Async mode as well.

In `test/Kafka/Streamly/StreamTest.hs`, add the two constructors to `fatalErrors`
(lines 32–52) so the pin becomes 20 fatal + 3 non-fatal, and add one behavioral case
to `skipNonFatalTests`: a stream of
`[Right 1, Left (KafkaResponseError RdKafkaRespErrFatal), Right 2]` filtered by
`skipNonFatal` must keep the fatal — this is the exact regression that made
`skipNonFatal` drop the death signal.

Because the poll action inside `kafkaStreamNoClose` is not injectable (it calls
`pollMessage` on a concrete `KafkaConsumer`; verified at `Stream.hs:109-118`), do not
attempt a stream-level fenced simulation in the unit suite; the taxonomy pin plus the
`skipNonFatal` case cover the defect, and the optional broker demo below covers the
end-to-end path. State this limitation in a comment above the new test case.

Update `hw-kafka-streamly/CHANGELOG.md` under a new `## Unreleased` heading (the file
follows Keep a Changelog; this is a behavior change for `isFatal` — under PVP this is
at least a minor bump; the actual release is shared with sibling plan 137, which also
edits `Stream.hs` in disjoint sections — coordinate: whichever plan lands second cuts
the release).

Acceptance for M2: with only the test-file change applied, `cabal test` fails on the
two new taxonomy cases and the `skipNonFatal` case; with the source change applied it
passes.

### Milestone 3 — pin recipe and propagation notes

Scope: make the consuming repos build against the fork. At the end,
`hw-kafka-streamly` builds against the pinned fork, and the stanzas for the other two
repos are recorded here for adoption on their next build (per MasterPlan 23's
Integration Points, this plan owns the recipe; consumers adopt when they next build —
do not edit `kafka-effectful` or `shibuya-kafka-adapter` beyond what is written here).

Append to `/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly/cabal.project` (which
currently has only `packages:`, `with-compiler`, `test-show-details`, and
`allow-newer` stanzas):

```cabal
-- hw-kafka-client fork: surfaces consumer-queue fatal errors in async
-- callback-poll mode and fixes the polled-message leak. Pinned until
-- the upstream PR merges and a release ships.
-- Upstream PR: <PR URL — fill in from M1>
source-repository-package
  type: git
  location: https://github.com/shinzui/hw-kafka-client.git
  tag: <commit hash — fill in from M1>
```

Use the full 40-character commit hash, never a branch name (branches move; the pin
must be reproducible). Run `cabal build all` and `cabal test` in
`/Users/shinzui/Keikaku/bokuno/hw-kafka-streamly` to prove resolution.

For `kafka-effectful` (`/Users/shinzui/Keikaku/bokuno/kafka-effectful`): the repo has
*no* `cabal.project` today (verified; cabal builds from the bare `.cabal` file).
Adopting the pin there requires creating one:

```cabal
packages: .

source-repository-package
  type: git
  location: https://github.com/shinzui/hw-kafka-client.git
  tag: <same commit hash>
```

For `shibuya-kafka-adapter`
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/cabal.project`):
append the same stanza after the existing `hs-opentelemetry` source-repository-package
block (that block is the in-repo precedent for the stanza shape, including `subdir:`
usage, which this pin does not need).

Record both snippets here (done above); the owning plans/maintainers apply them on
next build. Sibling plan 136's tests rely on surfaced-fatal behavior *only* if its
repo has adopted this pin — flag that in its Decision Log when the hash exists.

Optional end-to-end demo (evidence, not gating): with the Redpanda harness in the
hw-kafka-streamly repo (`process-compose.yaml` starts `rpk container start`), run two
consumers with the same `group.instance.id` and observe the first stream terminate.
Exact steps in Concrete Steps.


## Concrete Steps

All commands are exact; working directory is stated before each block.

Milestone 1 — in the new fork clone:

```bash
cd /Users/shinzui/Keikaku/bokuno
gh repo fork haskell-works/hw-kafka-client --clone --fork-name hw-kafka-client
cd hw-kafka-client
git checkout -b fix/async-consumer-fatal-observability v5.3.0
```

Building needs librdkafka headers/libs. The corpus project's dev shell provides them:

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-client
nix develop /Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project --command cabal build hw-kafka-client
nix develop /Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project --command cabal test hw-kafka-client-test
```

If the dev shell fails to apply to the outside clone, `brew install librdkafka` and
plain `cabal build` is the fallback. Expected test output ends with something like:

```text
Test suite hw-kafka-client-test: PASS
```

(The package also has `tests-it`, broker-backed integration tests; they are not
required here — they need a running Kafka and are excluded by default.)

After committing and pushing:

```bash
git push -u origin fix/async-consumer-fatal-observability
gh pr create --repo haskell-works/hw-kafka-client \
  --title "fix(consumer): surface consumer-queue fatal errors and destroy polled messages in async callback mode" \
  --body-file PR_BODY.md
git rev-parse HEAD   # record this hash in plan 135 (M3 stanzas + Progress)
```

Milestone 2 — in hw-kafka-streamly:

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly
cabal build all
cabal test hw-kafka-streamly-test
```

Expected before the source fix (with only test pins updated): two failures named
`fatal: RdKafkaRespErrFatal` and `fatal: RdKafkaRespErrSaslAuthenticationFailed`, plus
the new `skipNonFatal` case. Expected after: all pass, e.g.

```text
All 60 tests passed (0.01s)
Test suite hw-kafka-streamly-test: PASS
```

(the exact count depends on the suite; the point is zero failures).

Milestone 3 — pin adoption in hw-kafka-streamly:

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly
# edit cabal.project as specified in Plan of Work
cabal update
cabal build all 2>&1 | head -20   # expect "Cloning into ..." / the fork commit in the plan
cabal test hw-kafka-streamly-test
```

Optional fenced-consumer demo (requires Docker for `rpk container`):

```bash
cd /Users/shinzui/Keikaku/bokuno/hw-kafka-streamly
just process-up          # starts Redpanda on localhost:9092
just create-topic        # creates jitsurei-topic
```

Then write a scratch program (or extend `hw-kafka-streamly-jitsurei`) that builds
props with `extraProps` including `group.instance.id = "demo-instance"` twice, in two
OS processes, both subscribing to `jitsurei-topic` with the same `groupId`, in
`CallbackPollModeSync` (or Async under the M1 pin). Start process A, wait for
assignment, start process B. Acceptance: process A's stream ends with
`Left (KafkaResponseError RdKafkaRespErrFatal)` (Sync) or the resolved fenced code
(Async under pin) within the session timeout, instead of polling timeouts forever.
Capture the transcript into Surprises & Discoveries. Tear down with
`just process-down`.


## Validation and Acceptance

The plan is complete when all of the following hold, in order:

1. The fork branch builds and its unit suite passes (`cabal test
   hw-kafka-client-test` → `PASS`), the diff contains no `void $
   rdKafkaConsumerPoll`, and an upstream PR is open with the evidence-based body.
2. In `hw-kafka-streamly`, `git stash` of the source change makes the updated
   `StreamTest` fail on exactly the new cases; unstashed, `cabal test
   hw-kafka-streamly-test` passes. This demonstrates the tests actually pin the fix.
3. With the pin stanza in `hw-kafka-streamly/cabal.project`, `cabal build all`
   resolves `hw-kafka-client` from the fork commit (visible in the build log) and the
   suite still passes.
4. This document's Progress section is fully checked, the fork commit hash and PR URL
   are recorded, and the pin snippets for `kafka-effectful` and
   `shibuya-kafka-adapter` are present (they are, above — verify the hash is filled
   in).
5. ADR distillation: write the candidate ADR named by MasterPlan 23 — the consumer
   fatal-observability contract (which layer surfaces what, in which poll mode, and
   the Async watchdog caveat) — into keiro's `docs/adr/` as a new numbered ADR, and
   note it in the master plan's Progress. Coordinate with sibling plans 136/137,
   which contribute their own rows to the same contract; whichever plan finishes last
   completes the ADR.

Behavioral acceptance (the one-sentence version a human can check): after this plan,
a fenced consumer produces a `Left` fatal value in the stream within one poll
interval, in both poll modes, and `skipNonFatal` passes it through — before this
plan, Async mode hung silently and Sync mode retried/dropped it forever.


## Idempotence and Recovery

Every step is re-runnable. The fork clone can be deleted and re-created; the branch
re-cut from the same tag. Cabal edits are additive stanzas — removing the
`source-repository-package` block restores the Hackage 5.3.0 resolution exactly. If
the upstream PR is rejected or upstream requests a different design (for example
Route B), keep the pin (it is correct regardless) and open a follow-up plan for the
redesign; the pin is the deliverable our stack depends on, the PR is the exit
strategy. If the M1 `KafkaConf` field addition breaks a pattern match in code this
plan did not anticipate, GHC lists every site; fix mechanically. If `nix develop` of
the corpus project cannot build the outside clone, the brew fallback plus
`--extra-include-dirs`/`--extra-lib-dirs` flags to cabal is the documented recovery.


## Interfaces and Dependencies

At the end of M1 the fork exposes, in addition to the unchanged 5.3.0 surface:
`Kafka.Internal.RdKafka.rdKafkaFatalError :: RdKafkaTPtr -> IO (RdKafkaRespErrT,
Text)`; a `KafkaConf` with a fatal-sink field (internal); and changed semantics on
`Kafka.Consumer.pollMessage` / `pollMessageBatch` (fatal reported in-band in Async
mode) and `pollConsumerEvents` (destroys what it consumes). No exported function
changes type. At the end of M2, `Kafka.Streamly.Stream.isFatal` returns `True` for
`KafkaResponseError RdKafkaRespErrFatal` and `KafkaResponseError
RdKafkaRespErrSaslAuthenticationFailed`; no signatures change. Dependency versions in
play, verified from `dist-newstyle/cache/plan.json` in each repo: `hw-kafka-client`
5.3.0 (to be replaced by the fork commit), `streamly-core` 0.3.0, GHC 9.12.2. The
librdkafka reference copy is 2.13.2. Sibling plan 136 consumes the corrected `isFatal`
table (its classifier must include the two new arms); sibling plan 137 shares the
`hw-kafka-streamly` package release — its bracket API and this plan's `isFatal` arms
land in `Stream.hs` in disjoint sections, and `StreamTest.hs` conflicts are resolved
by keeping both plans' cases.
