---
id: 136
slug: classify-poll-and-commit-errors-and-fix-traced-context-hygiene
title: "Classify poll and commit errors and fix traced-context hygiene"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md"
---

# Classify poll and commit errors and fix traced-context hygiene

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`kafka-effectful` (`/Users/shinzui/Keikaku/bokuno/kafka-effectful`) is the effectful
wrapper our services use to consume Kafka. Its consumer interpreters have three
correctness defects and zero test coverage. First (KSC-4), `pollMessage` throws on
*every* non-timeout in-band error — including routine, partition-scoped conditions
such as partition EOF and auto-offset-reset — so a healthy consumer can be killed and
crash-looped by events that its own batch variant, and `hw-kafka-streamly`, correctly
keep in-band. Second (KSC-5), the commit operations throw on `RdKafkaRespErrNoOffset`,
which `hw-kafka-client` itself documents as "not to be considered an error" (it just
means there was nothing new to commit); `shibuya-kafka-adapter` hand-works around
this, `shikigami` does not and can die on an idle shutdown commit. Third (KSC-6 plus
the KSC-1 residual), the traced interpreter attaches each record's extracted trace
context to the thread-local storage and never detaches it, so a headerless record
gets parented to the *previous* record's remote trace — contradicting the module's
own documentation ("new root span when no inbound context is present") — and any
record with a non-UTF-8 header silently loses its inbound context while spamming a
warning, because the header decoding uses partial `decodeUtf8`.

After this plan: routine broker events (EOF, offset reset, idle commit) never kill a
healthy consumer; fatal errors still throw; a headerless record after a traced record
starts a new root exactly as documented; non-UTF-8 headers cannot break context
extraction; and the consumer interpreters have their first test suite, which pins all
of the above. You can see it working by running `just test` in the kafka-effectful
repo: the new `ClassifyTest`, `InterpreterTest`, and `ConsumerSpanTest` groups fail
against the old code and pass against the new.

This plan is EP-2 of MasterPlan 23
(`docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md`).
It soft-depends on EP-1
(`docs/plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md`): the
poll-error classifier here should agree with the *corrected* `isFatal` table that plan
adds to `hw-kafka-streamly` (two new fatal arms). Proceed against the current table
and re-sync when 135 lands — the classifier below already includes the two arms, so
"re-sync" normally means "verify nothing else changed". Sibling
`docs/plans/137-guarantee-deterministic-consumer-close-in-hw-kafka-streamly.md` does
not touch this repo. Per MasterPlan 23's Integration Points, this plan owns both
consumer interpreters and the new test suite; nothing else touches them.


## Progress

- [ ] M1: Poll-error classification added (pure classifier + both interpreters);
      `NoOffset` commits succeed in both interpreters; `pollMessageEither` added;
      `Effect.hs` docs updated.
- [ ] M2: Traced-context hygiene fixed (extract into empty context, attach/detach with
      token, per-record isolation in batch); header decoding total and filtered to
      propagator fields.
- [ ] M3: First consumer-interpreter test suite added and green; each regression test
      verified to fail against the pre-fix code (red-state transcript captured).
- [ ] Post-135 sync: classifier compared against `hw-kafka-streamly` `isFatal` after
      plan 135 lands; result recorded in Decision Log.


## Surprises & Discoveries

Findings from plan-authoring verification (2026-07-23):

- Drift from the review's framing of KSC-4, verified in librdkafka 2.13.2 (corpus at
  `/Users/shinzui/Keikaku/hub/librdkafka-project/librdkafka`):
  `RD_KAFKA_RESP_ERR__AUTO_OFFSET_RESET` is delivered as a consumer error only when
  the reset target is invalid — i.e. `auto.offset.reset=error`, or a reset that
  itself fails (`src/rdkafka_offset.c:821-843`); a *successful* reset after retention
  loss only logs a warning (`src/rdkafka_offset.c:862-883`). The librdkafka v1.6.1
  changelog confirms: "The consumer error raised by `auto.offset.reset=error` now has
  error-code set to `ERR__AUTO_OFFSET_RESET`". So the crash-loop scenario requires
  that configuration (or truncation/reset failure), not merely retention loss under
  default configs. The classification fix is unchanged — the condition is
  partition-scoped and non-fatal to the consumer — but this plan documents the
  accurate trigger.
- The context leak is precisely the undetached `attachContext`:
  `hs-opentelemetry-api`'s `inSpan''` internally snapshots the thread-local context
  entry and restores it after the span ends
  (`api/src/OpenTelemetry/Trace/Core.hs:673-708` in the corpus at
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry`) —
  restores it to the *post-attach* state. So after `withConsumerSpan` returns, the
  thread-local permanently holds the record's extracted context. There is no
  context-passing variant of `inSpan''`; the fix must manage the thread-local
  explicitly with the `Token` that `attachContext` returns
  (`api/src/OpenTelemetry/Context/ThreadLocal.hs:202-210`; `detachContext` at line
  238, documented "Pass the token to 'detachContext' to restore the previous
  context").
- KSC-1 refutation confirmed at `api/src/OpenTelemetry/Propagator.hs:264-278` (the
  review cited ~267–281; same block): `extract` catches `SomeException`, logs
  `"Propagator extract failed: ..."` via `otelLogWarning`, and returns the input
  context — so a non-UTF-8 header costs the inbound context plus a warning per
  record, never a crash.
- The "NoOffset is not an error" documentation is at
  `src/Kafka/Consumer/Callbacks.hs:37-39` of hw-kafka-client 5.3.0 (the review said
  `Callbacks.hs`; it is the `Consumer` subdirectory's file). Content as cited.
- A broker-free live repro for the NoOffset defect likely exists: `newConsumer`
  against an unreachable broker succeeds (librdkafka connects lazily), and
  `commitAllOffsets` with no assignment yields `RdKafkaRespErrNoOffset`. M3 uses
  this; if it yields a different error on some platform, fall back to the pure
  classifier tests and record what was observed here.


## Decision Log

- Decision: Keep `pollMessage`'s public contract "returns `Nothing` on no-message,
  throws on serious errors", and *swallow* (return `Nothing` for) the benign
  partition-scoped in-band conditions — `RdKafkaRespErrPartitionEof`,
  `RdKafkaRespErrAutoOffsetReset`, `RdKafkaRespErrUnknownTopicOrPart` — rather than
  change its return type; add `pollMessageEither` for callers that need every in-band
  condition. All other non-timeout errors continue to throw.
  Rationale: Changing `pollMessage`'s result to a richer type breaks every caller
  (`shikigami` calls it at
  `/Users/shinzui/Keikaku/bokuno/shikigami/shikigami-core/src/Shikigami/Trigger/Consumer.hs:91,118`;
  `keiro-runtime-jitsurei` and `shibuya-kafka-adapter` also depend on kafka-effectful
  per `mori registry dependents`). Swallowing only conditions that librdkafka itself
  treats as flow-control keeps loop-shaped callers (all known ones) correct: EOF means
  "caught up", offset-reset means "position moved", unknown-topic occurs in
  topic-creation windows and resolves itself. `pollMessageEither` preserves full
  fidelity for bounded reads (EOF detection) without breaking anyone. The alternative
  "throw only on `isFatal`-fatal errors, `Nothing` otherwise" was rejected: it would
  hide genuinely actionable transport errors that today's callers rely on seeing as
  crashes.
  Date: 2026-07-23

- Decision: Swallowed conditions are visible in the design, not just dropped: both
  interpreters route classification through one exported pure function
  (`classifyPollError`) so the policy is testable and documented, and the `pollMessage`
  haddock names the swallowed codes. No logging is added.
  Rationale: kafka-effectful's interpreters have zero logging infrastructure;
  inventing one inside a correctness fix couples this plan to a design debate. A
  future telemetry plan can add counters (MasterPlan 23 scopes span reshaping out for
  the same reason).
  Date: 2026-07-23

- Decision: Treat `RdKafkaRespErrNoOffset` as success in all three commit operations
  (`CommitOffsetMessage`, `CommitAllOffsets`, `CommitPartitionsOffsets`) in both
  interpreters.
  Rationale: hw-kafka-client documents NoOffset as not-an-error
  (`src/Kafka/Consumer/Callbacks.hs:37-39`); `shibuya-kafka-adapter` already
  hand-implements exactly this mapping
  (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter/shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs:186-189`),
  proving the need at a call site; the library must return what its dependency
  documents as success (MasterPlan 23 Decomposition, rejected alternative). Covering
  `CommitOffsetMessage` too (not just the two named in the finding) costs nothing and
  removes an inconsistency trap.
  Date: 2026-07-23

- Decision: In `withConsumerSpan`, extract the record's trace context into
  `OpenTelemetry.Context.empty` (not into the current thread-local context), attach
  it keeping the returned `Token`, and detach in a bracket after `inSpan''`
  completes.
  Rationale: Extract-into-empty delivers the documented contract directly: headers
  present → remote parent; headers absent → empty context → `inSpan''` creates a new
  root. Extract-into-current (today's code) inherits whatever the thread-local holds,
  which after the first record is the previous record's remote context (see Surprises
  & Discoveries). Detach-with-token restores whatever ambient context the caller had,
  giving per-record isolation in `PollMessageBatch` and no leakage into subsequent
  effect operations. Note the trade-off this codifies: the record span will *not* be
  a child of any ambient application span — that is what the module has always
  promised (new root or remote parent, nothing else), and message-consumer spans
  parented to remote producers is the OTel-conventional shape. The zero-duration-span
  observation (the span wraps `pure cr`, lines 130 and 139) is explicitly out of
  scope per MasterPlan 23's Decision Log — reshaping the span to cover user
  processing needs a handler-wrapping API and belongs to a telemetry initiative; this
  plan only notes it in the module docs.
  Date: 2026-07-23

- Decision: Fix header decoding with both proposed measures: decode with
  `Data.Text.Encoding.decodeUtf8Lenient` (total, replaces bad bytes with U+FFFD) *and*
  filter headers to the global propagator's declared fields (`propagatorFields`)
  before building the extraction carrier.
  Rationale: Both are cheap. Lenient decoding removes the exception source entirely
  (today `extract`'s catch masks it at the cost of the whole context). Filtering means
  an application payload header with arbitrary bytes never even reaches the decoder,
  and shrinks the carrier to what the propagator can use (typically `traceparent`,
  `tracestate`, `baggage`). Filtering by the propagator's own field list rather than a
  hard-coded set keeps custom propagator stacks working.
  Date: 2026-07-23

- Decision: Test the traced-interpreter hygiene through `withConsumerSpan` directly
  (exporting it), driving it with hand-built `ConsumerRecord` values and asserting
  via `getContext` and span trace ids — not through a real broker, and not through
  effect-level fakes.
  Rationale: The interpreters close over a live `K.KafkaConsumer` and call
  hw-kafka-client IO directly, so effect-level fakes cannot reach the defect; the
  defect lives in `withConsumerSpan`, which is broker-independent. The producer side
  offers no reusable fake either — the existing suite (verified) covers only the OTel
  helper modules (`PropagationTest`, `SemanticTest`, `ShibuyaCompatibilityTest`), and
  `PropagationTest` already demonstrates the pattern this plan reuses:
  `withResource initializeGlobalTracerProvider`, hand-built records, a known
  `traceparent` constant, and `hs-opentelemetry-exporter-in-memory` (already a test
  dependency).
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All code edits happen in `/Users/shinzui/Keikaku/bokuno/kafka-effectful` (package
`kafka-effectful`, version 0.3.0.0, GHC 9.12.2; the repo has no `cabal.project` —
cabal builds from the bare `.cabal` file; `just test` runs
`cabal test kafka-effectful-test`). Read-only reference repos: hw-kafka-client 5.3.0
at `/Users/shinzui/Keikaku/hub/haskell/hw-kafka-client-project/hw-kafka-client`,
hs-opentelemetry 1.0.0.0 at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry`,
librdkafka 2.13.2 at `/Users/shinzui/Keikaku/hub/librdkafka-project/librdkafka`.
Resolved dependency versions (from `dist-newstyle/cache/plan.json`): `text` 2.1.2,
`hs-opentelemetry-api` 1.0.0.0, `hs-opentelemetry-sdk` 1.0.0.0, `effectful-core`
2.6.1.0, `tasty` 1.5.3.

ADR context: keiro's `docs/adr/` contains only
`0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job telemetry) — not
relevant to this plan. No relevant ADR exists. kafka-effectful's own repo has a
`docs/` directory; the documentation sweep in Concrete Steps checks it for prose that
contradicts the new contracts.

Terms, in plain language. An *interpreter* here is the function that receives the
`KafkaConsumer` effect's operations and runs real hw-kafka-client IO for them; there
is a plain one and a traced (OpenTelemetry) one, identical except the traced one
opens a span per polled record. *In-band error* means an error value returned inside
the poll result (`Left err`) rather than thrown. The *thread-local context* is
hs-opentelemetry's per-thread mutable slot holding the current trace `Context`;
`getContext` reads it, `attachContext` swaps a new one in and returns a `Token`, and
`detachContext token` restores the previous one (LIFO). A *carrier* is the key-value
view (`TextMap`) a propagator reads during `extract`; here it is built from Kafka
record headers. `propagatorFields` returns the header names the configured
propagator consumes (SDK default stack: `traceparent`, `tracestate`, `baggage`).

The five files you will touch, and what is in them today:

`src/Kafka/Effectful/Consumer/Effect.hs` — the `KafkaConsumer` effect GADT
(operations: `PollMessage`, `PollMessageBatch`, three commit ops, store, assign,
pause/resume, seek, queries, `AskConsumerHandle`). The `pollMessage` smart
constructor's haddock at lines 112–114 documents the current throwing behavior:
"Throws 'KafkaError' via the 'Error' effect for any non-timeout failure".

`src/Kafka/Effectful/Consumer/Interpreter.hs` — the plain interpreter
`runKafkaConsumer`. `PollMessage` at lines 67–72: timeout → `pure Nothing` (line
70), *everything else* → `throwError` (line 71). `PollMessageBatch` at lines 73–74
passes the `[Either KafkaError ...]` through unchanged — the in-band taxonomy
`pollMessage` lacks. The three commit ops at lines 75–77 all use `throwOnJust`
(defined lines 92–94), which throws whatever `Maybe KafkaError` hw-kafka-client
returns — including `Just (KafkaResponseError RdKafkaRespErrNoOffset)` from an idle
commit. The consumer handle is bracket-managed (lines 40–60): note the release
closes the consumer, which is why a poll throw crash-loops a supervised service —
each restart re-subscribes and re-hits a persistent partition condition.

`src/Kafka/Effectful/OpenTelemetry/Consumer/Interpreter.hs` — the traced interpreter
`runKafkaConsumerTraced`. Same poll/commit shapes (`PollMessage` at 125–130,
`throwOnJust` commits at 140–142, helper at 157–159). Its module doc promises at
lines 11–13: "rooted at the W3C trace context extracted from the record's Kafka
headers (or as a new root span when no inbound context is present)". The defect is
in `withConsumerSpan` (lines 181–199): line 191 reads the current thread-local
context (`getContext`), line 192 merges the record's headers into it
(`extractTraceContextFromRecord cr currentCtx`), line 193 attaches the result and
*discards the `Token`* (`void $ attachContext inboundCtx`), line 194 opens the span
with `inSpan''` around the action — which at both call sites is `pure cr` (lines 130
and 139), so the span is a zero-duration point closed before any processing (noted,
out of scope). Because the token is discarded, nothing ever detaches: record N's
context is still attached when record N+1 arrives, so a headerless N+1 chains onto
N's remote trace, violating the module contract; the leak also walks across
`PollMessageBatch` entries (each `openSpanForResult`, lines 137–139, calls
`withConsumerSpan`) and persists after the poll operation returns.

`src/Kafka/Effectful/OpenTelemetry/Propagation.hs` — header/carrier bridges.
`kafkaHeadersToTextMap` (lines 49–56) decodes *every* header key and value with
partial `Data.Text.Encoding.decodeUtf8` (text 2.1.2: throws `UnicodeException` on
invalid UTF-8). `extractTraceContextFromRecord` (lines 97–103) feeds that carrier to
the global propagator's `extract`, whose catch-all (see Surprises & Discoveries)
converts the exception into "context dropped + one warning logged" per affected
record.

`test/` — `Main.hs` runs three tasty groups, all OTel-helper tests; no test touches
either consumer interpreter (the "zero consumer-interpreter coverage" of MasterPlan
23). `test/Kafka/Effectful/OpenTelemetry/PropagationTest.hs` shows the established
pattern to copy: `withResource initializeGlobalTracerProvider (\_ -> pure ())`,
hand-built `ConsumerRecord`s (fields `crTopic`, `crPartition`, `crOffset`,
`crTimestamp`, `crHeaders`, `crKey`, `crValue`; `headersFromList` from
`Kafka.Types`), and the W3C example traceparent
`00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01`.

Why the poll taxonomy matters operationally (verified): partition EOF
(`enable.partition.eof=true`) is delivered per catch-up, so a consumer that reaches
the end of a partition dies immediately under the current throw;
`UnknownTopicOrPart` appears during topic-creation windows; auto-offset-reset (under
`auto.offset.reset=error` or a failed reset, `src/rdkafka_offset.c:827-839`) is
delivered before any new commit can advance, so the bracket-close-restart cycle
repeats indefinitely. None of these is fatal to the consumer; contrast
`pollMessageBatch` and `hw-kafka-streamly`, which hand the same conditions to the
caller in-band and continue.


## Plan of Work

### Milestone 1 — poll and commit classification

Scope: one new pure module, edits to both interpreters, one new effect operation,
doc updates. At the end, an idle `commitAllOffsets` returns unit instead of
throwing, `pollMessage` survives EOF/reset/unknown-topic, `pollMessageEither`
exists, and the pure classifier is exported and unit-testable.

Create `src/Kafka/Effectful/Consumer/Classify.hs` (add to `exposed-modules` in
`kafka-effectful.cabal`) containing, with full haddocks explaining each category and
citing the librdkafka behavior in one sentence each:

```haskell
-- | How the interpreters treat an in-band poll error.
data PollErrorDisposition
    = PollTimeout   -- ^ 'RdKafkaRespErrTimedOut': no message; poll returns 'Nothing'.
    | PollBenign    -- ^ Partition-scoped flow-control condition; poll returns 'Nothing'.
    | PollThrow     -- ^ Anything else, including fatal errors: thrown via 'Error'.
    deriving stock (Eq, Show)

classifyPollError :: KafkaError -> PollErrorDisposition

-- | 'True' exactly for commit results that mean "nothing to commit",
-- which hw-kafka-client documents as not-an-error.
isBenignCommitError :: KafkaError -> Bool
```

`classifyPollError` maps `KafkaResponseError RdKafkaRespErrTimedOut` to
`PollTimeout`; `RdKafkaRespErrPartitionEof`, `RdKafkaRespErrAutoOffsetReset`, and
`RdKafkaRespErrUnknownTopicOrPart` to `PollBenign`; everything else to `PollThrow`.
Note in the haddock that `PollThrow` deliberately includes `RdKafkaRespErrFatal` and
`RdKafkaRespErrSaslAuthenticationFailed` — the fatal arms plan 135 adds to
`hw-kafka-streamly`'s `isFatal` — and that this table must be re-checked against
that function when plan 135 lands (the Progress item). `isBenignCommitError` is
`(== KafkaResponseError RdKafkaRespErrNoOffset)`.

In `src/Kafka/Effectful/Consumer/Interpreter.hs`: rewrite the `PollMessage` arm to
dispatch on `classifyPollError` (`PollTimeout` and `PollBenign` → `pure Nothing`,
`PollThrow` → `throwError err`); replace `throwOnJust` in the three commit arms
(lines 75–77) with a `throwOnJustCommit` that first drops benign commit errors:

```haskell
    throwOnJustCommit action' = do
        mbErr <- Effectful.liftIO action'
        for_ mbErr $ \err ->
            if isBenignCommitError err then pure () else throwError err
```

Keep plain `throwOnJust` for the non-commit operations — store/assign/seek keep
today's behavior. Add the new effect operation to the GADT in `Effect.hs`:

```haskell
    PollMessageEither ::
        Timeout ->
        KafkaConsumer m (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))
```

with a smart constructor `pollMessageEither` documented as "every in-band condition
returned as `Left`; nothing swallowed; use this for bounded reads that must observe
partition EOF". Implement it in both interpreters as a plain pass-through of
`K.pollMessage` (the traced interpreter opens a span only on `Right`, mirroring its
batch arm). Update `pollMessage`'s haddock (`Effect.hs:109-114`) to the new
contract, naming the three swallowed codes and the accurate auto-offset-reset
trigger (`auto.offset.reset=error` or a failed reset — see Surprises &
Discoveries).

Mirror the same `PollMessage`/commit changes in
`src/Kafka/Effectful/OpenTelemetry/Consumer/Interpreter.hs` (its arms at 125–130 and
140–142) — both interpreters must import the classifier so the tables cannot drift.

Acceptance: `cabal build` clean; the M3 tests for this milestone flip from red to
green; `grep -rn "throwOnJust \$ K.commit" src/` returns nothing.

### Milestone 2 — traced-context hygiene and total header decoding

Scope: `withConsumerSpan` and `Propagation.hs`. At the end, per-record context
isolation holds, headerless records are new roots, and no header bytes can abort
extraction.

Rewrite `withConsumerSpan` (`OpenTelemetry/Consumer/Interpreter.hs:181-199`) to:

```haskell
withConsumerSpan tracer props cr action = do
    semOpts <- Effectful.liftIO $ lookupStability "messaging" <$> getSemanticsOptions
    inboundCtx <-
        Effectful.liftIO $ extractTraceContextFromRecord cr Context.empty
    Exception.bracket
        (attachContext inboundCtx)
        detachContext
        ( \_token ->
            inSpan'' tracer (consumerSpanName (crTopic cr)) (spanArgs semOpts) $
                \_span -> action
        )
```

with imports adjusted: `OpenTelemetry.Context qualified as Context` (for `empty`),
`detachContext` added to the `OpenTelemetry.Context.ThreadLocal` import, and
`Effectful.Exception` (already imported qualified as `Exception`) providing
`bracket`. Key points to state in the haddock: extraction into `Context.empty` (not
the ambient context) is what makes "no headers → new root" true even immediately
after a traced record; the token bracket restores the caller's ambient context
whatever happens; the span still wraps only `pure cr` — reshaping it to cover user
processing is out of scope per MasterPlan 23's Decision Log, and the module doc
should say so explicitly so nobody mistakes the zero-duration span for a bug fixed
here. Export `withConsumerSpan` from the module (add to the export list under an
"Internal — exported for tests" haddock section); M3 drives it directly.

In `src/Kafka/Effectful/OpenTelemetry/Propagation.hs`: change
`kafkaHeadersToTextMap` to use `Text.decodeUtf8Lenient` for both keys and values
(same import module; total; U+FFFD replacement), and change
`extractTraceContextFromRecord` to filter the header list to the propagator's own
fields before building the carrier:

```haskell
extractTraceContextFromRecord record ctx = do
    propagator <- getGlobalTextMapPropagator
    let fields = propagatorFields propagator
        carrier =
            textMapFromList
                [ (key, Text.decodeUtf8Lenient v)
                | (k, v) <- headersToList (crHeaders record)
                , let key = Text.decodeUtf8Lenient k
                , key `elem` fields
                ]
    extract propagator carrier ctx
```

(`propagatorFields` comes from `OpenTelemetry.Propagator`; add it to the import
list. Keep `kafkaHeadersToTextMap` itself lenient-but-unfiltered, since
`PropagationTest` round-trips arbitrary headers through it and `inject` uses its
inverse.) Update the module haddock (lines 43–47 currently claim "decoded as UTF-8,
matching upstream" — now: decoded leniently, filtered to propagator fields during
extraction; note the divergence from the upstream instrumentation's partial
decoding and why).

Acceptance: M3's context-isolation and non-UTF-8 tests pass; `PropagationTest`'s
existing round-trip cases still pass (lenient decoding is the identity on valid
UTF-8).

### Milestone 3 — the first consumer-interpreter test suite

Scope: three new test modules wired into `test/Main.hs` and the cabal test stanza.
At the end, every defect this plan fixes has a test that failed before the fix, and
the red-state transcript is captured in this plan.

`test/Kafka/Effectful/Consumer/ClassifyTest.hs` — pure tests, no IO: the three
benign codes classify `PollBenign`; `RdKafkaRespErrTimedOut` is `PollTimeout`;
`RdKafkaRespErrFatal`, `RdKafkaRespErrSaslAuthenticationFailed`, and a
representative transport error (e.g. `RdKafkaRespErrDestroy`) are `PollThrow`;
`isBenignCommitError` accepts exactly `NoOffset` and rejects a non-commit error.
Mirror the taxonomy-pin style of `hw-kafka-streamly`'s
`test/Kafka/Streamly/StreamTest.hs` (label + expected pairs) so the two tables can
be eyeballed against each other during the post-135 sync.

`test/Kafka/Effectful/Consumer/InterpreterTest.hs` — live-interpreter tests using a
consumer against an unreachable broker (no Docker needed; librdkafka connects
lazily). Build props with `brokersList [BrokerAddress "localhost:1"]` plus a
`groupId`, subscribe to any topic name, and run
`runEff . runError @KafkaError . runKafkaConsumer props sub` around: (a)
`pollMessage (Timeout 100)` → expect `Right Nothing` (timeout swallowed — passes
today too; it pins the unchanged half of the contract); (b)
`commitAllOffsets OffsetCommit` → expect `Right ()` — the KSC-5 regression test;
before the fix it returns `Left (KafkaResponseError RdKafkaRespErrNoOffset)`. Keep
timeouts short (~100 ms) so the suite stays fast; comment that these tests exercise
a real librdkafka client with no broker, with the fallback noted in Surprises &
Discoveries if platform variance appears. In-band benign classification at the
interpreter level cannot be forced without a broker (a real client will not emit
`PartitionEof` offline) — that path is covered by `ClassifyTest` plus both
interpreters' shared use of the classifier; state this in a comment.

`test/Kafka/Effectful/OpenTelemetry/ConsumerSpanTest.hs` — the hygiene tests,
driving the exported `withConsumerSpan` directly. Provide a `mkRecord ::
[(ByteString, ByteString)] -> ConsumerRecord (Maybe ByteString) (Maybe ByteString)`
helper via `headersFromList` (other fields: any topic/partition/offset,
`NoTimestamp`, `Nothing` key and value — copy from `PropagationTest`). To assert on
created spans, construct a *local* tracer provider wired to
`hs-opentelemetry-exporter-in-memory` (already a test dependency) in the group's
`withResource` acquire, take a `Tracer` from it, and pass that tracer to
`withConsumerSpan`; also call `initializeGlobalTracerProvider` once so the global
propagator (used by `extractTraceContextFromRecord`) is the SDK's W3C stack. Follow
the exporter package's haddocks for construction and record the exact recipe here
once written. Cases:

1. *Traced record gets remote parent*: record with the sample traceparent; the
   exported span's trace id renders as `0af7651916cd43dd8448eb211c80319c`
   (`traceIdBaseEncodedText Base16` — see `PropagationTest` imports).
2. *Headerless-after-traced is a new root* (the KSC-6 regression): run
   `withConsumerSpan` with the traced record, then with a headerless record, on the
   same thread; the second span's trace id differs from the sample and it has no
   parent. Before the fix the second span chains onto the first record's remote
   trace.
3. *Ambient context restored*: `getContext` before the two calls equals
   `getContext` after (the token bracket restores it). Before the fix the
   thread-local retains the last record's context.
4. *Non-UTF-8 header does not poison extraction* (KSC-1 residual): record with
   headers `[("traceparent", <sample>), ("payload-hint", "\xc3\x28")]` (an invalid
   UTF-8 sequence): the span still gets the sample trace id. Before the fix the
   partial decode throws inside the carrier build, `extract`'s catch drops the
   whole context, and the span becomes a root.
5. *Batch isolation*: call `withConsumerSpan` in sequence for [traced, headerless,
   traced-with-a-second-trace-id] and assert each span's trace id independently —
   this pins the `PollMessageBatch` walk.

Wire all three modules into `test/Main.hs` and `other-modules` of the
`kafka-effectful-test` stanza; extend `build-depends` only as the compiler demands
(`effectful-core` provides `runEff`/`runError`; everything else is already listed).

Acceptance: `just test` green; red-state captured per Concrete Steps.


## Concrete Steps

Working directory for everything: `/Users/shinzui/Keikaku/bokuno/kafka-effectful`.

```bash
cd /Users/shinzui/Keikaku/bokuno/kafka-effectful
cabal build kafka-effectful          # after each milestone's edits
just test                            # = cabal test kafka-effectful-test
```

Expected final output shape (counts will differ):

```text
Kafka.Effectful.OpenTelemetry
  Semantic: OK
  Propagation: OK
  ShibuyaCompatibility: OK
Kafka.Effectful.Consumer
  Classify: OK
  Interpreter (brokerless): OK
  ConsumerSpan: OK
All NN tests passed
Test suite kafka-effectful-test: PASS
```

Capture the red state once (regression evidence). Order the work as: write M3's
`InterpreterTest` and `ConsumerSpanTest` first, run them against the unfixed source,
save the failures, then apply M1/M2:

```bash
cabal test kafka-effectful-test 2>&1 | grep -B2 -A6 "FAIL" | head -60
```

Expected failing evidence before the fixes: the commit test reporting
`Left (KafkaResponseError RdKafkaRespErrNoOffset)`; the new-root test reporting the
second span carrying trace id `0af7651916cd43dd8448eb211c80319c`; the ambient test
reporting unequal contexts; the non-UTF-8 test reporting a root span. Paste the
actual lines into Surprises & Discoveries. (`ClassifyTest` cannot run pre-fix — the
module does not exist yet; it is a pin, not a regression test.)

Documentation sweep at the end:

```bash
grep -rn "pollMessage\|NoOffset" docs/ README.md CHANGELOG.md | head -20
```

Update any prose stating the old contracts, and add a CHANGELOG entry under
`## Unreleased` describing: benign poll conditions swallowed, NoOffset commits
succeed, `pollMessageEither` added, traced context isolation fixed, lenient header
decoding (mention that per-record `Propagator extract failed` warnings disappear).
This is a behavior change: plan the next release as at least a minor PVP bump.


## Validation and Acceptance

Complete when:

1. `just test` passes with the three new test groups present, and the red-state
   transcript for the NoOffset, new-root, ambient-restore, and non-UTF-8 cases is
   recorded in this plan.
2. `pollMessage`'s haddock, the traced interpreter's module doc, and
   `Propagation.hs`'s haddocks match the shipped behavior (three swallowed codes
   named; new-root semantics stated as implemented; zero-duration-span note with its
   out-of-scope pointer to MasterPlan 23's Decision Log).
3. Both interpreters import the classifier — verify:
   `grep -l "Consumer.Classify" src/Kafka/Effectful/Consumer/Interpreter.hs
   src/Kafka/Effectful/OpenTelemetry/Consumer/Interpreter.hs` lists both files.
4. The post-135 sync item is resolved: once
   `docs/plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md`
   lands its `isFatal` change (20 fatal arms), diff that table against
   `classifyPollError`'s `PollThrow` coverage and record agreement (or justified
   divergence) in this plan's Decision Log. Note: if plan 135's fork ships the
   *resolved original cause* code for Async-mode fatals (its M1 fourth step allows
   either), `PollThrow`'s catch-all already covers any such code — no change needed,
   but say so.
5. Blast radius: `shikigami` and `shibuya-kafka-adapter` compile unchanged against
   the new kafka-effectful on their next build (no removals; `pollMessageEither` is
   additive). The shibuya adapter's hand-rolled NoOffset catch (`Kafka.hs:186-189`)
   becomes dead-but-harmless; leave it to that repo to delete opportunistically.
6. ADR distillation: contribute the interpreter taxonomy rows (what throws, what is
   swallowed, what NoOffset means, the context-isolation contract) to the
   fatal-observability-contract ADR MasterPlan 23 names; whichever of plans
   135/136/137 finishes last completes that ADR in keiro's `docs/adr/`.

Behavioral acceptance in one sentence: an idle consumer that commits nothing, hits
a partition EOF, or crosses an offset reset keeps running; a fenced or
transport-broken consumer still crashes loudly; traces never chain across unrelated
records; non-UTF-8 headers cost nothing; and all of it is pinned by tests that
demonstrably failed before.


## Idempotence and Recovery

All edits are additive or in-place rewrites guarded by tests; re-running builds and
tests is always safe. `PollMessageEither` is additive — if it causes unexpected
friction it can be dropped without affecting the rest of this plan (the classifier
and commit fixes do not depend on it); record such a retreat in the Decision Log.
If the brokerless `commitAllOffsets` test proves flaky (timing or platform variance
in librdkafka), demote it to the classifier test plus a comment, and record the
observed variance in Surprises & Discoveries. If exporting `withConsumerSpan` is
judged too public, move it to a new
`Kafka.Effectful.OpenTelemetry.Consumer.Internal` module instead — the tests only
need *a* stable import path. If `Effectful.Exception.bracket`'s masking interacts
badly with `inSpan''`'s own masking (unlikely; both are standard bracket shapes),
fall back to explicit `attachContext`/`detachContext` with
`Exception.finally` and record it.


## Interfaces and Dependencies

End state of the public surface (all in kafka-effectful):

- `Kafka.Effectful.Consumer.Classify` (new, exposed):
  `data PollErrorDisposition = PollTimeout | PollBenign | PollThrow`;
  `classifyPollError :: KafkaError -> PollErrorDisposition`;
  `isBenignCommitError :: KafkaError -> Bool`.
- `Kafka.Effectful.Consumer.Effect`: new operation `PollMessageEither` and smart
  constructor `pollMessageEither :: (KafkaConsumer :> es) => Timeout -> Eff es
  (Either KafkaError (ConsumerRecord (Maybe ByteString) (Maybe ByteString)))`;
  `pollMessage`'s type unchanged, contract re-documented. Re-export
  `pollMessageEither` wherever `pollMessage` is re-exported (check
  `src/Kafka/Effectful.hs` and `src/Kafka/Effectful/Consumer.hs`).
- `Kafka.Effectful.OpenTelemetry.Consumer.Interpreter`: additionally exports
  `withConsumerSpan` (internal-for-tests section); `runKafkaConsumerTraced` type
  unchanged.
- `Kafka.Effectful.OpenTelemetry.Propagation`: `kafkaHeadersToTextMap` total;
  `extractTraceContextFromRecord` filters to `propagatorFields`; types unchanged.

Dependencies used (no version-bound changes expected): `text` 2.1.2
(`decodeUtf8Lenient`, available since text 2.0; the library stanza's bound is
already `>=2.0 && <2.2`), `hs-opentelemetry-api` 1.0.0.0
(`attachContext`/`detachContext` tokens, `OpenTelemetry.Context.empty`,
`propagatorFields`, `inSpan''`), `hs-opentelemetry-exporter-in-memory` ^>=1.0
(already in the test stanza), `effectful-core` 2.6.1.0, `hw-kafka-client` 5.3.0 —
or plan 135's fork pin once this repo adopts it (adoption recipe: create
`cabal.project` with `packages: .` plus the `source-repository-package` stanza
recorded in plan 135's Milestone 3; none of this plan's tests require the pin,
since nothing here depends on Async-mode fatal surfacing).
