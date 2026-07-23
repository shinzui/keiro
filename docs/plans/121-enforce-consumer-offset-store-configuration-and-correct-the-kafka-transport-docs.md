---
id: 121
slug: enforce-consumer-offset-store-configuration-and-correct-the-kafka-transport-docs
title: "Enforce consumer offset-store configuration and correct the Kafka transport docs"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md"
---

# Enforce consumer offset-store configuration and correct the Kafka transport docs

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Two adoption traps from the July 2026 transport review, fixed in two independent milestones. First (finding KFK-5, confirmed): shibuya-kafka-adapter's entire at-least-once guarantee silently depends on the *caller* remembering to pass `noAutoOffsetStore` in consumer properties that the adapter never sees and cannot verify. A service that copies consumer properties from any non-shibuya example passes every test and then loses messages on its first crash — with librdkafka's default (`enable.auto.offset.store=true`), offsets of merely-*polled* messages are stored and auto-committed, so a crash between poll and the handler's durable effect (keiro's inbox commit) is silent message loss. After milestone 1, that misconfiguration is impossible-by-construction or fails fast at wiring time with a clear error, in the adapter itself. Second (finding KFK-4, confirmed contradictions in both directions): keiro's Kafka guide still documents a header-drop defect as *current* and steers integration-event consumers *away* from the adapter, although the defect was fixed upstream in adapter 0.7.0.0; meanwhile keiro's production-status page claims keiro "ships" Kafka producer/consumer adapters when in fact `Keiro.Outbox.Kafka` and `Keiro.Inbox.Kafka` are pure record/envelope converters and zero code connects keiro to librdkafka. After milestone 2, both documents tell the truth and describe the fixed transport built by the sibling plans.

Work locations: milestone 1 is code in the **shibuya-kafka-adapter** repository at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter` (this plan file lives in keiro, but that milestone's commands all run in the adapter repo — working directories are stated on every command). Milestone 2 is documentation in **keiro** at `/Users/shinzui/Keikaku/bokuno/keiro`. Per the master plan's Integration Points, this plan owns `docs/guides/integration-events-with-kafka.md` and `docs/user/production-status.md` (keiro-repo-relative) **exclusively** — the sibling plans must not edit them, and everything those files need from the siblings is consumed via the siblings' Decision Logs. Note also: keiro has **no library dependency** on shibuya-kafka-adapter or kafka-effectful — the coupling is contract and documentation (plus a test-suite-only dependency decision recorded in sibling plan 120), which is exactly why these documents are the integration surface and must be correct.

This plan is child EP-3 of the master plan at `docs/masterplans/18-make-the-kafka-transport-edge-production-safe-surfaced-by-the-2026-07-transport-review.md`. Siblings by path: `docs/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter.md` (defines the adapter release this milestone-1 change rides or follows) and `docs/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge.md` (defines the publish API name and reference bridge the guide will describe). Milestone 1 is independent and can start immediately; milestone 2 soft-depends on both siblings' Decision Logs. The names and semantics used below reflect those Decision Logs as of authoring; **at implementation time, re-read both siblings' Decision Logs and quote whatever they record** — if they changed, update this plan's text (and note the change at the bottom) before writing the docs.


## Progress

- [ ] Milestone 1: `OffsetStoreVerified` witness type and `runShibuyaKafkaConsumer` wrapper added to the adapter; explicit `enable.auto.offset.store=true` fails fast.
- [ ] Milestone 1: `kafkaAdapter`/`kafkaAdapterWith` require the witness; `unsafeOffsetStoreVerified` escape hatch documented.
- [ ] Milestone 1: unit tests added (wrapper injects the property; explicit-true fails fast; escape hatch compiles); integration tests and jitsurei examples migrated to the wrapper; suite green.
- [ ] Milestone 1: adapter CHANGELOG entry written; release coordination with plan 119 settled (ride 0.9.0.0 or cut 0.10.0.0) and recorded in the Decision Log.
- [ ] Milestone 2: sibling Decision Logs re-read; names/versions confirmed or this plan updated.
- [ ] Milestone 2: guide consumer section rewritten (header claim corrected to 0.7.0.0-fixed; adapter recommended; wrapper recipe; honest caveat tied to the 119 release).
- [ ] Milestone 2: guide publish/bridge section rewritten around `produceMessageBatchAcked` and the reference bridge; mandated producer properties stated.
- [ ] Milestone 2: `production-status.md` transport claims made truthful.
- [ ] Milestone 2: diff audit confirms only the two owned files changed in keiro's docs; master plan Progress updated.

## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Enforce the offset-store configuration with an adapter-owned consumer-scope wrapper plus a witness type — `runShibuyaKafkaConsumer` composes the caller's `ConsumerProperties` with `noAutoOffsetStore` (right-biased semigroup makes the adapter's setting win), fails fast when the caller *explicitly* set `enable.auto.offset.store=true`, and is the only exported source of an `OffsetStoreVerified` value, which `kafkaAdapter`/`kafkaAdapterWith` now require. A loudly named `unsafeOffsetStoreVerified` escape hatch exists for callers with exotic wiring.
  Rationale: the three candidate mechanisms were checked against the actual representations. (1) A startup assertion against the *live* consumer is not implementable: hw-kafka-client exposes no config readback from a consumer handle (no `rd_kafka_conf_get` binding on the live object — verified by searching `hw-kafka-client/src`), and the adapter runs inside the `KafkaConsumer` effect scope, after the properties are consumed by `newConsumer`. (2) A checked smart constructor for properties alone still lets the caller pass the checked value to a *different* `runKafkaConsumer` call than the one the adapter lives in, or skip the check entirely. (3) Owning the scope is enforceable because `ConsumerProperties` is a transparent record (`cpProps :: Map Text Text`, exported, hw-kafka-client `src/Kafka/Consumer/ConsumerProperties.hs:52-57`) whose `Semigroup` is right-biased (`M.union m2 m1` — the *right* operand's keys win; same file, lines 59-62), so `props <> noAutoOffsetStore` deterministically forces `enable.auto.offset.store=false`; and a witness whose constructor is unexported makes "adapter without the wrapper" a compile error rather than a runtime hope. Failing fast on explicit `true` (rather than silently overriding) respects the caller's stated intent — a caller who explicitly demanded auto-store has a broken mental model that must surface at wiring time, with `KafkaInvalidConfigurationValue` (a `KafkaError` constructor carrying `Text`, hw-kafka-client `src/Kafka/Types.hs:101`).
  Date: 2026-07-23

- Decision: Release coordination — this plan's adapter change is breaking (new required argument on `kafkaAdapter`/`kafkaAdapterWith`) and **rides plan 119's 0.9.0.0 release** when the two land together; if this milestone lands after 0.9.0.0 has shipped, it cuts 0.10.0.0. The guide's version bound in milestone 2 quotes whichever release actually carries *both* the ordering fixes and this enforcement.
  Rationale: the master plan's Integration Points assign the version-bump definition to plan 119 with this plan riding or cutting next; one breaking release is kinder to the fleet than two.
  Date: 2026-07-23

- Decision: The guide names the publish API exactly as `produceMessageBatchAcked` with signature `[ProducerRecord] -> Eff es [Either KafkaError Offset]`, per sibling plan 120's Decision Log, and points at the compiled reference bridge `Keiro.TestBridge.Kafka.publishOutboxBatchAcked` in keiro's test suite rather than embedding a freestanding recipe.
  Rationale: the master plan requires the name to be quoted identically to EP-2's record; excerpting compiled code prevents the guide-only rot this initiative is eliminating.
  Date: 2026-07-23

- Decision: The docs milestone corrects the header-fix version to 0.7.0.0 (not 0.8 as the master plan's prose says), citing commit `424a4c2`.
  Rationale: verified against the adapter's history during authoring — commit `424a4c2` ("feat!: surface Kafka headers on Envelope and require shibuya-core 0.7", 2026-06-05) and the `shibuya-kafka-adapter/CHANGELOG.md` section "0.7.0.0 — 2026-06-05" both record the verbatim header pass-through, with the current release at 0.8.0.1; docs being written to be *truthful* must not repeat the master plan's off-by-one-release description. Reproduce the evidence with `git show --stat 424a4c2` from `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### ADRs

keiro's `docs/adr/` contains only `0001-keiro-pgmq-job-processing-telemetry-contract.md` (pgmq job-processing telemetry) — not relevant to the Kafka edge; no relevant ADR exists. The adapter repository has no `docs/adr/` directory. The master plan lists the consumer ordering guarantee and the acked-publish contract as ADR candidates at initiative completion; if milestone 1's enforcement design proves durable, add it to that ADR pass.

### Finding KFK-5 in full — the unverified property the whole guarantee hangs on

The adapter's offset lifecycle: on `AckOk` it calls `storeOffsetMessage` (mark the offset ready), and librdkafka's auto-commit later flushes stored offsets to the broker. This "store only after the handler succeeded" discipline is the entire at-least-once story — and it only works if *automatic* offset store is off. The adapter *documents* the requirement: `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs:142-144` says "The adapter uses @noAutoOffsetStore@ with manual @storeOffsetMessage@ + auto-commit for offset management." But it never sees the properties: `Shibuya/Adapter/Kafka/Config.hs:14-19` states "Consumer properties (brokers, group ID, etc.) are provided when running @runKafkaConsumer@ — the adapter operates /within/ the @KafkaConsumer@ effect scope, not outside it", and `KafkaAdapterConfig` carries only `topics`, `pollTimeout`, `batchSize`. The only wiring-time check the adapter performs is `warnOnSubscriptionMismatch` (`Kafka.hs:192-208`) — topics only, and only a stderr warning. `noAutoOffsetStore` itself is just `extraProps (M.fromList [("enable.auto.offset.store", "false")])` (hw-kafka-client `src/Kafka/Consumer/ConsumerProperties.hs`, the function after `noAutoCommit`). With librdkafka's default `enable.auto.offset.store=true`, every polled message's offset is stored on delivery to the app; auto-commit then commits it regardless of what the handler did. Crash (OOM-kill, deploy, panic) between poll and the handler's durable effect → the message is committed-past and never redelivered. Nothing in any test fails when the property is missing, because tests don't crash at the wrong moment. That is the trap: **correct-looking, fully green, lossy**.

Wiring surface today, from the adapter's own module example (`Kafka.hs:9-25`): the caller runs `runKafkaConsumer props sub` (from `kafka-effectful`, `src/Kafka/Effectful/Consumer/Interpreter.hs:34-46` — it passes `props` straight to `K.newConsumer`) and inside that scope calls `kafkaAdapter (defaultConfig [...])`. `kafkaAdapter`/`kafkaAdapterWith` (`Kafka.hs:155-190`) take only the config. So enforcement must intercept the properties *before* `newConsumer`, in code the adapter owns — see the Decision Log entry for the mechanism analysis and the exact design.

### Finding KFK-4 in full — the two documentation contradictions

(i) `docs/guides/integration-events-with-kafka.md` (keiro-repo-relative), in the section "Reading Kafka records — the integration choice" (heading at line 156): lines 166-197 present "Option B — shibuya-kafka-adapter, with a caveat to know about", claiming the adapter's `consumerRecordToEnvelope` "**only preserves `traceparent` and `tracestate` headers**" (lines 175-176), that keiro-specific headers "are dropped at the adapter boundary", and concluding that integration-event consumers should prefer "Option A" (raw `kafka-effectful`) until an "upstream patch" lands. **This is false and has been since adapter 0.7.0.0** (commit `424a4c2`, 2026-06-05): `Shibuya/Adapter/Kafka/Convert.hs:62-68` materializes every Kafka header verbatim (`headerList = headersToList cr.crHeaders`; `headers = Just headerList` — ordered, duplicates preserved, `Just []` for a headerless record) onto the `Envelope.headers` field that `shibuya-core` has carried since 0.7 (`shibuya/shibuya-core/src/Shibuya/Core/Types.hs:97`, `headers :: !(Maybe Headers)`); `ConvertTest.hs:91-99` pins order and duplicate preservation. The Kafka topic is also recoverable: the envelope's `messageId` is `"{topic}-{partition}-{offset}"` (`Convert.hs:96-99`), parseable from the right since partition and offset are numeric. So the "upstream patch" the guide asks for shipped over a year of releases ago, and the guide is steering consumers away from the *better* path.

(ii) `docs/user/production-status.md` lines 29-32 claim keiro ships "a transactional outbox with per-key ordering, backoff, and dead-lettering, **plus a Kafka producer adapter**" and "an idempotent inbox ... **plus Shibuya and Kafka consumer adapters**". In reality `Keiro.Outbox.Kafka` (`keiro/src/Keiro/Outbox/Kafka.hs`) and `Keiro.Inbox.Kafka` (`keiro/src/Keiro/Inbox/Kafka.hs`) are pure record/envelope converters — their own haddocks say keiro "deliberately does not import @hw-kafka-client@ or @kafka-effectful@" and "It is pure: the caller supplies the bytes and the @Text@-keyed header map produced by its Kafka adapter" — and zero code in any keiro package connects to librdkafka (no keiro `.cabal` references hw-kafka-client or kafka-effectful; verified during authoring; sibling plan 120 adds a *test-suite-only* dependency for the reference bridge).

### What the corrected docs may confidently claim (verified sound, carried forward)

These review-verified behaviors are the honest backbone of the rewritten guide: store-only-on-`AckOk` means the crash window produces **duplicates, never loss** — *given* the enforced `enable.auto.offset.store=false` from milestone 1, which is what turns that sentence from "if configured correctly" into a guarantee; `commitAllOffsets` on shutdown drains stored offsets (`Kafka.hs:184-190`, tolerating `RdKafkaRespErrNoOffset` when idle); and the fatal/transient error taxonomy (non-fatal poll noise filtered via hw-kafka-streamly's `skipNonFatal`, genuinely fatal errors surfacing through the `Error KafkaError` scope) is real and tested upstream. The *ordering* guarantee (a failed record blocks successors) is only true once plan 119's release ships — the guide must tie that claim to the release version, not state it unconditionally.


## Plan of Work

### Milestone 1 — wiring-time enforcement in shibuya-kafka-adapter (independent; start immediately)

Scope: the adapter's public wiring surface. At the end, it is a compile error to construct the Kafka adapter without going through code that guarantees `enable.auto.offset.store=false`, an explicitly contradictory configuration fails fast with a clear error, and the adapter's tests and examples all use (and thereby document) the new entry point. All work in `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`.

1. In `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` add, near the top of the module (new "Consumer scope" export group):

   ```haskell
   -- | Evidence that the surrounding 'KafkaConsumer' scope was created with
   -- @enable.auto.offset.store=false@. The only exported ways to obtain one
   -- are 'runShibuyaKafkaConsumer' (which guarantees it) and
   -- 'unsafeOffsetStoreVerified' (which asserts it — see its warning).
   data OffsetStoreVerified = OffsetStoreVerifiedInternal

   runShibuyaKafkaConsumer ::
       (IOE :> es, Error KafkaError :> es) =>
       ConsumerProperties ->
       Subscription ->
       (OffsetStoreVerified -> Eff (KafkaConsumer : es) a) ->
       Eff es a
   runShibuyaKafkaConsumer props sub action =
       case Map.lookup "enable.auto.offset.store" (cpProps props) of
           Just "true" ->
               throwError
                   ( KafkaInvalidConfigurationValue
                       "shibuya-kafka-adapter requires enable.auto.offset.store=false \
                       \(store-after-success is the adapter's at-least-once mechanism), \
                       \but the supplied ConsumerProperties explicitly set it to true. \
                       \Remove that property; runShibuyaKafkaConsumer sets it for you."
                   )
           _ ->
               runKafkaConsumer (props <> noAutoOffsetStore) sub
                   (action OffsetStoreVerifiedInternal)

   -- | Escape hatch for callers that must create the consumer scope
   -- themselves. By using this value you assert that the consumer was
   -- created with @enable.auto.offset.store=false@; if that is not true,
   -- the adapter silently commits offsets of unprocessed messages and a
   -- crash loses them. Prefer 'runShibuyaKafkaConsumer'.
   unsafeOffsetStoreVerified :: OffsetStoreVerified
   unsafeOffsetStoreVerified = OffsetStoreVerifiedInternal
   ```

   Export `OffsetStoreVerified` **abstractly** (type only, no constructor), plus `runShibuyaKafkaConsumer` and `unsafeOffsetStoreVerified`. New imports: `Kafka.Consumer.ConsumerProperties (ConsumerProperties, cpProps, noAutoOffsetStore)`, `Kafka.Consumer.Subscription (Subscription)`, `Kafka.Effectful.Consumer.Interpreter (runKafkaConsumer)` (or the `Kafka.Effectful.Consumer` re-export — match the repo's import style), and `KafkaInvalidConfigurationValue` from `Kafka.Types`. The composition direction matters and deserves the comment it gets above: hw-kafka-client's `ConsumerProperties` semigroup is right-biased, so the adapter's `noAutoOffsetStore` (the right operand) wins over anything in `props` — the fail-fast branch exists only to surface *explicit* caller intent to the contrary rather than silently overriding it.
2. Thread the witness: change `kafkaAdapter` and `kafkaAdapterWith` to take `OffsetStoreVerified` as their first argument (the argument is evidence, unused at runtime — bind it as `_verified` and say so in the haddock). Update the module-header example (`Kafka.hs:9-25`) to the new shape:

   ```haskell
   main = runEff
     . runError @KafkaError
     $ runShibuyaKafkaConsumer props sub $ \verified -> do
         adapter <- kafkaAdapter verified (defaultConfig [TopicName "orders"])
         ...
   ```

3. Migrate in-repo callers (they double as documentation): `test/Kafka/TestEnv.hs` (builds consumer properties and calls `kafkaAdapter` — note it already passes `noAutoOffsetStore` explicitly, which remains fine: composing it twice is idempotent map union), each `shibuya-kafka-adapter-jitsurei/app/*.hs` example, and any `AdapterTest` construction sites. Delete the now-redundant explicit `noAutoOffsetStore` from migrated property lists *or* keep one example carrying it to show the override is harmless — choose the former for signal, and let the wrapper be the single source of the property.
4. Tests, in `test/Shibuya/Adapter/Kafka/AdapterTest.hs` (no broker needed for the first two):
   - *wrapper injects the property*: `cpProps (props <> noAutoOffsetStore)` contains `("enable.auto.offset.store","false")` even when `props` came from a bare `brokersList`+`groupId`; and when `props` maliciously contains the key with value `"true"` composed via `extraProps`, the composed map still reads `"false"` (right bias). This pins the semigroup direction the design depends on — if hw-kafka-client ever flips it, this test fires.
   - *explicit true fails fast*: run `runShibuyaKafkaConsumer (props <> extraProps (M.fromList [("enable.auto.offset.store","true")])) sub (\_ -> pure ())` under `runErrorNoCallStack @KafkaError` and assert `Left (KafkaInvalidConfigurationValue _)` **without** a consumer ever being created — use an unroutable broker address so an accidental `newConsumer` attempt would error differently/slowly, proving the check precedes acquisition.
   - *integration path*: switch `TestEnv` to `runShibuyaKafkaConsumer` so the entire existing integration suite (10 cases, live Redpanda) exercises the wrapper end to end.
5. CHANGELOG entry (adapter house style), under whichever version this rides (see Decision Log — coordinate with plan 119; if riding 0.9.0.0, append to that section):

   ```markdown
   ### Breaking Changes

   - `kafkaAdapter` and `kafkaAdapterWith` now require an `OffsetStoreVerified`
     witness, obtained from the new `runShibuyaKafkaConsumer` wrapper (which
     composes `noAutoOffsetStore` into the consumer properties and fails fast
     with `KafkaInvalidConfigurationValue` if the caller explicitly set
     `enable.auto.offset.store=true`). This closes a silent message-loss
     misconfiguration: with librdkafka's default auto offset store, polled-but-
     unprocessed messages were committed on crash. `unsafeOffsetStoreVerified`
     exists for callers that must own the consumer scope themselves.
   ```

Acceptance: from the adapter repo root, `cabal test shibuya-kafka-adapter --test-options='-p "!/Integration/"'` green including the new cases; full suite green with Redpanda (`just process-up`, `just create-topics`); `cabal build all` proves the jitsurei examples compile against the new signatures; and a deliberate wrong-wiring spike — temporarily calling `kafkaAdapter` without a witness in a scratch file — fails to compile (do not commit the spike; note the observed error in Surprises & Discoveries as evidence).

### Milestone 2 — correct keiro's two transport documents (consumes sibling Decision Logs)

Scope: the two files this plan owns, in `/Users/shinzui/Keikaku/bokuno/keiro`. At the end, everything both documents say about the Kafka transport is true at time of writing, version-qualified where it depends on unreleased sibling work. Before touching either file, re-read `docs/plans/119-...md` and `docs/plans/120-...md` Decision Logs and confirm: the adapter release number (expected 0.9.0.0, possibly 0.10.0.0 for the enforcement — see this plan's Decision Log), the ordering-guarantee wording from 119, and the API name/signature and bridge module path from 120 (expected `produceMessageBatchAcked` and `Keiro.TestBridge.Kafka.publishOutboxBatchAcked`). Quote them verbatim.

1. `docs/guides/integration-events-with-kafka.md`, section "Reading Kafka records — the integration choice" (line 156 at authoring): delete the false Option-B caveat block (lines 166-197: the "only preserves traceparent and tracestate" claim, the "dropped at the adapter boundary" paragraph, and the two-option remedy list). Replace with prose that: (a) states the adapter surfaces **every** Kafka header verbatim on `Envelope.headers` since 0.7.0.0 (ordered, duplicates preserved, `Just []` when a record has none; the W3C pair appears both parsed in `traceContext` and verbatim in `headers`), citing commit `424a4c2` is unnecessary in a guide — cite the version; (b) shows the three-line hop from a shibuya `Envelope` to `integrationEventFromKafka`: decode `headers` bytes to `Text` pairs, build `KafkaInboundRecord`, derive the topic from the envelope's `messageId` (`"{topic}-{partition}-{offset}"` — parse from the right, the last two segments are numeric) or carry it in the handler's closure per-topic; (c) makes the adapter the *recommended* path for integration-event consumers wanting supervision, with `kafka-effectful`-direct demoted to the minimal-dependency alternative; and (d) adds the honest caveat, version-tied: before adapter <RELEASE> (the number confirmed from plan 119's Decision Log), a handler failure lets already-buffered same-partition records execute first and, under consecutive failures, could skip a failed offset entirely — pin the guide's recipe to `shibuya-kafka-adapter >= <RELEASE>` and say why in one sentence.
2. Same file, "Wiring up the Kafka consumer" (line 117): update the wiring recipe to the milestone-1 entry point — `runShibuyaKafkaConsumer props sub $ \verified -> kafkaAdapter verified ...` — and state what it enforces (offset store off; fail-fast on explicit contradiction) so readers know they cannot reproduce the KFK-5 trap by copying properties from elsewhere.
3. Same file, "### 3. publishClaimedOutbox drains the row into Kafka" (lines 91-100) and the "bridge" mentions in "Guarantees, in plain language" (line 202 onward): replace "the caller-supplied batch publish function" hand-wave with the shipped reality: publish through `produceMessageBatchAcked` (`[ProducerRecord] -> Eff es [Either KafkaError Offset]`, broker-acked, one flush per batch, from `kafka-effectful >= 0.4`), producer configured with `enable.idempotence=true` (implies `acks=all`, `max.in.flight <= 5`) — state these as *mandated*, matching the API haddock; and point at the compiled reference bridge (`Keiro.TestBridge.Kafka.publishOutboxBatchAcked` in keiro's test suite, per plan 120) with a short excerpt of its per-key re-map explanation: a same-key success after a same-key broker failure in one batch is re-reported as failed, costing only a redundant republish under at-least-once. Keep the guarantees section's at-least-once framing and strengthen it: store-only-on-AckOk means crashes produce duplicates, never loss, *now enforced at wiring time* rather than assumed; `commitAllOffsets` shutdown drain and the fatal/transient taxonomy stay as-is (they were verified sound).
4. `docs/user/production-status.md` lines 29-32: rewrite the two bullets truthfully. Replace "plus a Kafka producer adapter" with wording of this shape (adjust to the surrounding list's voice): "a transactional outbox with per-key ordering, backoff, and dead-lettering, plus transport-neutral Kafka record conversion (`Keiro.Outbox.Kafka`) and a broker-acknowledged batch publish path via `kafka-effectful`'s `produceMessageBatchAcked`, with a compiled reference bridge in keiro's test suite"; and "plus Shibuya and Kafka consumer adapters" with "plus Kafka envelope decoding (`Keiro.Inbox.Kafka`) consumed through the external `shibuya-kafka-adapter` (see the integration guide); keiro itself does not link librdkafka". If the sibling releases have not shipped when this milestone runs, qualify with the pending version numbers rather than claiming shipped artifacts — the page's job is truth, not optimism.
5. Audit and bookkeeping: `git -C /Users/shinzui/Keikaku/bokuno/keiro diff --stat` must show only the two owned files (plus plan/masterplan files); update the master plan's EP-3 Progress checkboxes and this plan's Progress.

Acceptance: the greps in Validation all pass; a full read-through of both files finds no remaining claim contradicted by the code cited in Context and Orientation; the guide's only forward-looking statements are explicitly version-qualified.


## Concrete Steps

Milestone 1 — all from the adapter repo:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
nix develop
cabal build all
cabal test shibuya-kafka-adapter --test-options='-p "!/Integration/"'
```

Full suite (Redpanda in a second terminal: `cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter && nix develop && just process-up`):

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
just create-topics
cabal test shibuya-kafka-adapter
```

Expected: `All N tests passed`, N including the new enforcement cases. Commit (Conventional Commits): `feat!: require OffsetStoreVerified; runShibuyaKafkaConsumer enforces enable.auto.offset.store=false`.

Milestone 2 — all from the keiro repo. First re-read the sibling Decision Logs:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
sed -n '/## Decision Log/,/## Outcomes/p' docs/plans/119-fix-the-seek-barrier-ordering-and-stale-successor-execution-in-shibuya-kafka-adapter.md
sed -n '/## Decision Log/,/## Outcomes/p' docs/plans/120-add-an-acked-batch-publish-api-to-kafka-effectful-and-a-reference-outbox-bridge.md
```

Edit the two files, then verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
grep -n "only preserves" docs/guides/integration-events-with-kafka.md ; echo "exit=$?"
grep -n "produceMessageBatchAcked" docs/guides/integration-events-with-kafka.md
grep -n "runShibuyaKafkaConsumer" docs/guides/integration-events-with-kafka.md
grep -n "Kafka producer adapter" docs/user/production-status.md ; echo "exit=$?"
git diff --stat
```

Expected: the first grep prints nothing and `exit=1`; the middle greps each print at least one line; the "Kafka producer adapter" grep prints nothing with `exit=1`; the diff stat lists only `docs/guides/integration-events-with-kafka.md`, `docs/user/production-status.md`, this plan, and the master plan. Docs are not compiled, so also run keiro's test suite once to confirm the working tree is otherwise undisturbed (`cabal test keiro-test` — 335 examples baseline, or higher if plan 120's milestone 3 has landed; record which). Commit: `docs(kafka): correct transport guide and production-status to the fixed adapter and acked publish API`.


## Validation and Acceptance

Milestone 1 acceptance is behavioral: a consumer wired through `runShibuyaKafkaConsumer` with property lists copied from *any* non-shibuya example (no `noAutoOffsetStore` anywhere) runs with `enable.auto.offset.store=false` — pinned by the semigroup unit test and exercised live by the migrated integration suite; a consumer whose properties explicitly demand auto-store never starts, failing with `KafkaInvalidConfigurationValue` and the remediation text — pinned by the fail-fast unit test; and code that tries to build the adapter without evidence does not compile — demonstrated by the throwaway spike. Milestone 2 acceptance is the grep transcript above plus the read-through: every transport claim in both documents is either verified-current (headers since 0.7.0.0; store-after-success; shutdown drain; taxonomy) or explicitly version-gated (ordering guarantee at the 119 release; acked publish at kafka-effectful 0.4); and the documents' ownership boundary held (diff-stat audit).


## Idempotence and Recovery

Both milestones are safely repeatable: milestone 1 is additive API plus mechanical call-site migration (re-running builds/tests is free; if the migration stalls midway the package simply does not compile, which is the safe failure — finish or `git checkout -- .` in the adapter repo and restart); milestone 2 is prose in two files under version control (`git checkout -- docs/guides/integration-events-with-kafka.md docs/user/production-status.md` from the keiro root reverts cleanly). The one cross-plan hazard is release-number drift: if plan 119's version changes after milestone 2 has quoted it, the guide's bound is wrong — the recovery is mechanical (re-grep the guide for the version string and update), and the "re-read sibling Decision Logs first" step exists precisely to prevent it. If milestone 2 must ship before the sibling releases exist, keep every dependent claim version-qualified ("as of shibuya-kafka-adapter <RELEASE>, pending") — never state pending behavior as current; that is the failure mode this plan is deleting.


## Interfaces and Dependencies

Defined by this plan (milestone 1, in the `shibuya-kafka-adapter` library, module `Shibuya.Adapter.Kafka`):

- `data OffsetStoreVerified` — exported abstract (no constructor).
- `runShibuyaKafkaConsumer :: (IOE :> es, Error KafkaError :> es) => ConsumerProperties -> Subscription -> (OffsetStoreVerified -> Eff (KafkaConsumer : es) a) -> Eff es a`.
- `unsafeOffsetStoreVerified :: OffsetStoreVerified`.
- `kafkaAdapter :: (KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => OffsetStoreVerified -> KafkaAdapterConfig -> Eff es (Adapter es (Maybe ByteString))` and `kafkaAdapterWith` likewise gaining the leading witness argument.

Consumed from elsewhere (why): hw-kafka-client ≥5.3 `ConsumerProperties`/`cpProps`/`noAutoOffsetStore`/`Subscription` and `KafkaInvalidConfigurationValue` (the representations the enforcement inspects and the error it raises); kafka-effectful ^>=0.3 `runKafkaConsumer` (the scope the wrapper owns; note the *producer*-side 0.4 bump from plan 120 does not constrain this consumer path — the adapter's own bound moves only if the adapter starts using 0.4 features); shibuya-core ^>=0.8.0.1 unchanged. Milestone 2 depends on no libraries — its inputs are the two sibling plans' Decision Logs (paths in the preamble) and the verified code facts recorded in Context and Orientation; keiro itself gains no dependency from this plan, and the master plan's file-ownership rule (this plan alone edits the two keiro doc files) is the interface contract with the siblings.
