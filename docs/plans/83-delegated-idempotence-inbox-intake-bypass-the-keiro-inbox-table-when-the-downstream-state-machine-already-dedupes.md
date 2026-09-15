---
id: 83
slug: delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes
title: "Delegated-idempotence inbox intake: bypass the keiro_inbox table when the downstream state machine already dedupes"
kind: exec-plan
created_at: 2026-07-02T02:34:14Z
intention: "intention_01kwganm3be0q8z4g6rmcqdj05"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T18:44:35Z
      mode: "update"
      note: "Refresh current runtime and DSL contracts; correct delegated duplicate, failure, identity and batch APIs; require measured performance gates."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-15T18:56:09Z
      mode: "implement"
      note: "Implement delegated runtime wrappers and adapters; continue through DSL, conformance, performance, documentation, and ADR milestones."
---

# Delegated-idempotence inbox intake: bypass the keiro_inbox table when the downstream state machine already dedupes


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. This revision is grounded in commit `97c1c27a` on 2026-09-15. The delegated feature is not implemented.


## Purpose / Big Picture


Allow an integration-event consumer to avoid the `keiro_inbox` write when its downstream operation already durably prevents repeated effects. The new entry points compute the existing dedupe key, invoke an explicitly idempotent handler, and translate its report into `InboxResult`. They perform no database work themselves. Existing table-backed entry points remain the default.

An integration event is a public message whose producer-assigned `messageId` survives publication retries. A dedupe key identifies deliveries that a consumer considers the same operation. Delegation is safe only when the complete operation is protected by that identity: repeating it, concurrently or after a crash, must not repeat committed effects. A `DelegatedOutcome` is a caller assertion, not a type-level proof. Public constructors cannot establish that arbitrary IO is idempotent.

The primary demonstration is a deterministic aggregate append with its SQL effects in the same transaction: first delivery returns `InboxProcessed`, replay returns `InboxDuplicate`, the event and SQL effect exist once, and the inbox is neither read nor written. A declared `idempotence delegated` intake generates a typed delegated runner and receives persisted-identity compatibility gating.

Do not promise lower latency merely from fewer inbox rows. Aggregate deduplication needs an indexed read before command hydration, and delegated batches do not share a commit. Performance acceptance below measures those costs and blocks unbounded replay work or regressions hidden by baseline replacement.


## Progress


- [x] (2026-09-15) Refreshed the plan against current inbox, command, process-manager, workflow, DSL, benchmark, and fixture code; checked relevant ADRs and located dependency sources with Mori.
- [x] (2026-09-15) Replaced unsafe duplicate/workflow assumptions, specified error-safe batching and source-scoped identities, and added API compatibility and performance acceptance.
- [x] (2026-09-15 19:00Z) M1: Added runtime outcome, abstract validated retry context, and no-Store delegated single/retry/batch entry points. Focused tests passed with 7 examples and the complete `keiro-test` suite passed with 685 examples.
- [x] (2026-09-15 19:13Z) M2: Added the versioned length-prefixed identity and safe command/PM adapters. Golden vectors, preflight-before-invalid-dispatch, multi-event lost-ack recovery, no-receipt rejection, and collision confirmation all pass.
- [x] (2026-09-15 19:24Z) M3: Durable effects, races, retry boundaries, batch isolation, cancellation, and empty inbox state pass in 15 focused examples. A denied-inbox database role completes first delivery and replay while direct inbox access fails; the complete runtime suite passes with 694 examples.
- [ ] M4: Add a successor-language intake mode, preserve published languages, and extend existing validation, generation, and compatibility reporting.
- [ ] M5: Add generated and hand-filled delegated conformance under the advertised Haskell edition; run all DSL suites.
- [ ] M6: Record paired performance evidence, update user documentation and ADRs, and complete verification.


## Surprises & Discoveries


The old plan treated every `StoreFailed (DuplicateEvent _)` as success. Current `Keiro.ProcessManager.confirmBenignDuplicate` explicitly checks the attempted ID in the target stream, because event IDs are globally unique and the error may contain no parsed ID. Its companion `dispatchDeduplicatedCommand` probes before dispatch, avoiding hydration of an already-applied command. `eventAlreadyIn` now delegates to the store's indexed `eventExistsInStream`; it does not replay the stream.

The old PM fold mapped every nonduplicate constructor to fresh success. `PMCommandResult` includes `PMCommandFailed StreamName CommandError`, so that fold could acknowledge a failed command. A successful `CommandResult` can also report zero appended events; that does not establish a durable dedupe marker.

The proposed workflow helper was unsafe. `keiro/src/Keiro/Workflow.hs` explicitly documents at-least-once step effects across a crash between the action and journal commit. An instance row can describe suspended, failed, or cancelled work and is not a completion receipt. Its live `runWorkflow` signature additionally requires `Error StoreError :> es`. Remove the lookup-then-run helper from this plan.

The batch planner marks a key seen before its handler executes. That is suitable only in the existing table batch's transaction/fallback design; copying it into independent delegated calls could acknowledge a repeat after its first attempt failed. Exceptions also stop ordinary traversal unless caught. Delegated batching must record only confirmed successes and isolate synchronous exceptions per item.

DSL intake evolution already exists in `intakePairDiff`: `DedupeIdentityChanged` is breaking, while decode and persistence changes are advisory. The current AST uses `dedupeKey`, `dedupePolicy`, `persist`, and `disposition`, not `ink*` selectors. The parser is split into `Parser/Integration.hs`. Generated dispositions are service-specific types carrying retry/dead-letter details, not `InboxAck`.

Language 5 is published and stable, with no active candidate at the inspected commit. New syntax cannot widen it or add globally reserved words. The current `Justfile` runs all DSL suites through `cabal test keiro-dsl:tests`; `haskell-verify` does not build a website. Existing inbox benchmarks use no-op handlers and time a table reset within each sample, so they are unsuitable as an unchanged numerical comparator for a real downstream append.

The delegated wrappers can share the existing private `recordInboxResult` without acquiring `Store`; the metric helpers require only `MonadIO`. A successful delegated batch identity must enter its local `Set` after both `DelegatedFresh` and `DelegatedDuplicate`, while a policy error or caught synchronous exception must leave the identity absent. The focused suite confirmed this failure-then-repeat boundary and synchronized async cancellation propagation.

The live command tests expose an important race boundary: one concurrent delivery commits the marker and SQL effect; the other may observe either a confirmed duplicate or a safe command failure caused by state changing before its append. Redelivery then resolves through the marker preflight. A marker collision in another stream remains a failure, including duplicate errors that omit or mismatch the attempted ID.

The test fixture needed a preparation phase before opening its application-role resource store. Keeping the privileged preparation store and restricted application store sequential avoids leaking owner privileges into the proof. The restricted role has event-store and application-table permissions, schema visibility for the inbox, and no privileges on `keiro.keiro_inbox`; its direct inbox query fails while delegated command intake succeeds and replays as duplicate.


## Decision Log


The 2026-07-02 standalone scope and separate-entry-point decisions are retained. This is not a child of completed [master plan 11](../masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md). The table handler is a transaction action; the delegated handler is an effectful action whose downstream owns transactions. No mode flag should pretend those handler types are interchangeable.

On 2026-09-15, superseded the original witness claim: `DelegatedOutcome` records an explicit success/duplicate assertion but cannot prove effect confinement. Adapters and executable concurrency/crash tests supply evidence. Keep wrapper constraints at `IOE :> es`; only the downstream adapter needs `Store`.

On 2026-09-15, replaced the pure command-error fold with a dispatch adapter that probes first and confirms duplicate errors against the target stream. Preserve PM failures as failures and reject successful no-event commands from the convenience adapter. Such operations need their own durable receipt or must keep table-backed intake.

On 2026-09-15, removed `delegatedWorkflowStart`. Workflow instance existence and journal append uniqueness do not establish exactly-once effects. A future workflow-start API would need an atomic, durable acceptance/handoff contract and recovery proof; it is not a lookup added to this feature.

On 2026-09-15, changed batch suppression to a local set of successful `(source, dedupeKey)` identities, populated only after fresh or confirmed-duplicate success. Retain sequential input order and per-item failures. Do not refactor the table batch planner for this feature.

On 2026-09-15, retained explicit retry accounting but require a validated context. The caller owns durable attempts across restarts and rebalances; neither a Kafka offset nor these wrappers supplies such a counter. Metrics count observations and are not exactly-once durable counters. `InboxPreviouslyFailed` is reachable in the retrying delegated API.

On 2026-09-15, replaced delimiter-joined IDs with a frozen versioned, length-prefixed UTF-8 identity including consumer, source, dedupe key, target stream, and stable operation name. One ID guards the first event of the command's atomic append. Distinct commands need distinct stable operation names.

On 2026-09-15, extend existing intake diffing and gate syntax in a successor language. Generate an actual delegated runner so the selected mode affects the callable API. Preserve published table-generated output. These are implementation decisions in this plan; accepted ADR contracts are not changed by this documentation-only refresh.

On 2026-09-15, kept `DelegatedRetryContext` abstract while exporting read-only ceiling and attempt accessors for the runtime wrapper. The type omits `Generic`, so callers cannot reconstruct invalid values through generic product machinery, and the public constructor remains the only creation path.


## Outcomes & Retrospective


Milestones 1 through 3 are complete. The delegated wrappers compile without a Store interpreter, the adapter is proven through real command dispatch, 15 focused contract/live PostgreSQL examples pass, and the complete runtime suite passes with 694 examples. The durable test matrix covers first delivery, replay, lost acknowledgement, an invalid post-append replay, multi-event atomicity, concurrent delivery, foreign collisions, no-receipt failures, retry/poison boundaries, source-scoped batches, cancellation, and operation under a database role denied all inbox-table privileges. The DSL, conformance, performance evidence, documentation, and ADR distillation remain outstanding. No performance result is claimed.

At implementation completion, record test counts, the exact benchmark environment and raw artifact paths, throughput and allocation comparisons, remaining restrictions, and the resulting ADR references. Do not mark this plan complete on compilation alone.


## Context and Orientation


This Cabal monorepo contains `keiro/` (runtime), `keiro-core/` (integration envelope), `keiro-dsl/` (language and generation), and `keiro-test-support/` (isolated PostgreSQL fixtures). `keiro/src/Keiro/Inbox.hs` owns table entry points, batch planning, and the private `recordInboxResult`; `keiro/src/Keiro/Inbox/Types.hs` owns `InboxResult`, `InboxError`, `InboxDedupePolicy`, and pure `dedupeKeyFor`. `keiro/src/Keiro/Inbox/Schema.hs` supplies `listInbox :: Store :> es => Text -> Eff es [InboxRow]`.

Table identity is `(source, dedupe_key)`. `PreferIntegrationMessageId` requires a nonempty message ID; `PreferSourceEventIdentity` uses event ID, falling back to source global position; `KafkaDeliveryIdentity` requires delivery metadata; `CustomDedupeKey` rejects an empty key. Preserve these exact rules. Table-backed retention is a finite dedupe window, not permanent exactly-once delivery; its module documents the concurrent-GC caveat.

`keiro/src/Keiro/Command.hs` hydrates state before deciding whether to append. A replayed command can therefore reject in the new state before ever hitting event-ID uniqueness. `RunCommandOptions.eventIds` assigns supplied IDs to emitted events in order; remaining events get store-generated IDs. All events in one append commit atomically, so a deterministic first event guards that batch. `runCommandWithSql` and related transactional runners require the resource interpreter and carry additional typed store errors; use `withFreshResourceStore`/the `StoreRunner` harness in `keiro-test-support/src/Keiro/Test/Postgres.hs` for these tests.

`keiro/src/Keiro/ProcessManager.hs` exports `dispatchDeduplicatedCommand`, `eventAlreadyIn`, and `confirmBenignDuplicate`. The latter accepts only matching/missing duplicate IDs and confirms stream membership. `keiro/src/Keiro/Router.hs` demonstrates length-prefixed identity encoding. The downstream store is owned by `mori://shinzui/kiroku`; source artifacts used here are project-relative `kiroku-store/src/Kiroku/Store/Read.hs`, `SQL.hs`, and `Error.hs` (artifact-level source URI pending). Mori's current docs registry has no curated entries for it. Its SQL probe uses `SELECT EXISTS` over `stream_events` and a live stream-name lookup.

Relevant decisions are [ADR 24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md), which freezes UTF-8 identity recipes and requires unambiguous new encodings; [ADR 8](../adr/0008-workflow-failure-history-is-immutable-and-derived-terminal-state-is-revivable.md), which separates workflow history from revivable derived state; [ADR 16](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md), which freezes published languages and preserves located source provenance; [ADR 19](../adr/0019-generated-haskell-has-an-explicit-edition-and-local-extension-contract.md), which owns generated compilation editions; and [ADR 38](../adr/0038-keiro-dsl-records-use-concise-labels-without-product-selectors.md), which requires concise AST labels without product selectors.

The DSL touch points are `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, `Parser/Integration.hs`, `Parser/Document.hs`, `Parser/Core.hs`, `Frontend/Internal.hs`, `LanguageVersion.hs`, `PrettyPrint.hs`, `Skeleton.hs`, `Validate.hs`, `Scaffold.hs`, `Diff.hs`, and `DiffReport.hs`. Paths after the first are relative to the same `keiro-dsl/src/Keiro/Dsl/` directory. `Frontend/Internal.hs` reconstructs `IntakeNode` positionally, so adding a field requires updating it. The seven source disposition names remain `processed`, `duplicate`, `inProgress`, `previouslyFailed`, `decodeFailed`, `dedupeFailed`, and `storeFailed`; `InboxHandlerFailed` currently maps to the generated `storeFailed` disposition with failure details.


## Plan of Work


Six milestones deliver the runtime, adapters, live proof, DSL integration, compiled generation, and performance/documentation evidence. Implement runtime milestones before widening the language surface.


### Milestone 1 — No-store wrappers and explicit retry ownership


In `keiro/src/Keiro/Inbox/Types.hs`, add `DelegatedOutcome a = DelegatedFresh !a | DelegatedDuplicate` and `InboxIdempotence = IdempotenceInboxTable | IdempotenceDelegated`, deriving the usual `Generic`, `Eq`, and `Show`. Update `InboxDuplicate` documentation: delegated handlers may execute to determine a duplicate even though protected effects do not repeat.

Add abstract `DelegatedRetryContext` with an unexported constructor and `mkDelegatedRetryContext :: Int -> Int -> Either Text DelegatedRetryContext`, taking ceiling then current one-based attempt. Reject nonpositive values; accept attempts above the ceiling for terminal classification. Do not expose Generic-based reconstruction of this validated type. Callers validate configuration/delivery metadata before intake; existing `InboxError` remains the dedupe-policy error.

Implement the three signatures in Interfaces and Dependencies in `keiro/src/Keiro/Inbox.hs`. All paths compute policy errors before invoking handlers. The base single wrapper propagates handler exceptions and typed effects; successful results receive exactly one `recordInboxResult` call with no backlog sampling or timestamps.

The retry wrapper validates through its supplied context: at attempt greater than ceiling, return `InboxPreviouslyFailed Nothing` without invoking the handler. At or below the ceiling, catch only synchronous exceptions with existing `trySync`, returning `InboxHandlerFailed reason attempt`; success at the ceiling remains success. Use `recordInboxResult` with the ceiling. A failure at attempt equal to ceiling increments poisoned once for that invocation; repeated invocations with that count increment again. Never claim cross-process exactly-once metrics. A typed `Error e` effect is not automatically a synchronous exception: callers must explicitly handle downstream errors and apply their retry/dead-letter policy.

The batch API processes sequentially and catches synchronous handler exceptions per item, returning `InboxHandlerFailed reason 1` with no poison ceiling. It has no durable retry accounting. Use a strict `Set (Text, Text)` scoped to this call, adding identities only after `DelegatedFresh` or confirmed `DelegatedDuplicate`. Policy errors and exceptions never add entries. Suppressed repeats still increment duplicate metrics once. Build results by reverse accumulation or a single traversal, never repeated list append or indexing. Async cancellation propagates immediately. Callers supply bounded chunks; the function has O(n log n) set work and O(n) retained keys/results, and creates no threads or database transactions.

Acceptance: build `keiro`, run existing `keiro-test`, and add no-store tests with only IOE proving valid/invalid keys, retry boundaries, failure-then-repeat execution, result ordering, and cancellation. These API tests must compile without installing a Store interpreter.


### Milestone 2 — Safe downstream identity and adapters


Create `keiro/src/Keiro/Inbox/Delegated.hs` and expose it in `keiro/keiro.cabal`. Keep it separate from `Keiro.Inbox` to avoid a broad command/process-manager re-export. Reuse current process-manager primitives rather than duplicating SQL or scanning streams.

Define `delegatedEventId consumer source dedupe target operation`. Encode the ordered fields `["keiro/inbox-delegated/1", consumer, source, dedupe, targetStreamText, operation]` as UTF-8, prefixing each field with its decimal byte length and a colon, concatenate, and hash with UUID v5 namespaceURL. Follow the router's unambiguous encoding pattern; route seed-byte conversion through `Keiro.DeterministicId.identitySeedBytes`. Freeze golden IDs for ASCII, Unicode, empty-field boundaries, and delimiter-containing values. Different sources, consumers, targets, and operation names must differ even when message IDs coincide. No normalization, random salt, clock, or deployment-version component is allowed.

Expose `DelegatedCommandError = DelegatedCommandFailed !StreamName !CommandError | DelegatedCommandWithoutReceipt !StreamName`. The `delegatedCommand` adapter takes base options, the target stream name, the deterministic first-event ID, and a callback accepting the prepared options. It replaces `eventIds` with the singleton marker and invokes `dispatchDeduplicatedCommand` with that same singleton probe. The callback must use those supplied options and target, run exactly one atomic append, and include all protected SQL/outbox work in that append transaction. This is a documented precondition, not a proof enforced by the callback type.

Preflight hit returns duplicate without invoking the callback. A positive `eventsAppended` result returns fresh; zero returns `DelegatedCommandWithoutReceipt`. On errors, the existing duplicate confirmer protects against unrelated/global collisions; preserve nonbenign failures, including unconfirmed missing-ID collisions. A concurrent winner can cause a state rejection or conflict before a duplicate append: returning a failure is safe, and the next delivery's preflight must detect the winner. Do not turn arbitrary errors into duplicates.

The pure `delegatedFromPMCommand` adapter maps `PMCommandDuplicate` to duplicate, positive-event `PMCommandAppended` to fresh, zero-event results to without-receipt, and `PMCommandFailed stream err` to a typed failure preserving both values. It is valid for a single dispatch whose identity already absorbs the intake identity; it is not evidence that an entire multi-command manager reaction completed.

Adapters return typed `Either DelegatedCommandError`. Integration code must inspect Left and route retry/dead-letter explicitly; when using the retry wrapper it may translate a retryable error to its application exception inside the handler. Never wrap an `Either` in `DelegatedFresh`, which would acknowledge a Left.

There is no workflow adapter and no raw `delegatedFromCommand` error fold. General workflow bodies, silent commands, separately committed side effects, and arbitrary fan-out remain outside these convenience adapters. Acceptance: module builds, adapter cases are exhaustively tested, identity goldens pass, and Haddocks spell out each restriction.


### Milestone 3 — Durable behavior, races, and no-inbox proof


In `keiro/test/Main.hs`, add `describe "Keiro.Inbox delegated"` using the existing suite-level PostgreSQL fixture and resource-aware runner where needed. Use a real aggregate and a transactional SQL counter or projection; do not replace the durable proof with IORef-only tests.

Deliver the same event twice using `delegatedCommand`: assert processed then duplicate, one event batch, one counter change, and `listInbox source == []`. Make the replayed command invalid in the post-append state so the test proves preflight occurs before hydration/dispatch. Repeat for a multi-event append, then simulate loss of acknowledgement by discarding the first successful return and redelivering.

Race two independent connections on the same identity using a barrier. Assert exactly one committed event batch and SQL effect; the loser may be a confirmed duplicate or a retryable failure followed by duplicate on redelivery. Install an event with the same ID in another stream and prove it remains a failure. Test mismatched `DuplicateEvent (Just id)` and `DuplicateEvent Nothing` without target membership; neither is acknowledged. Prove zero-event and failed PM results never become processed.

Test batch sequences with a first synchronous failure followed by the same identity, successful duplicate suppression, mixed sources sharing a key, invalid policies, and unrelated messages after a poison message. Ensure input-order results and no success caching after failure. Retry cases include invalid context inputs, attempts 1/2/3/4 with ceiling 3, success at attempt 3, poisoned metrics at failing attempt 3, and no invocation at attempt 4. Verify async cancellation with a synchronized handler, not a timing sleep.

Zero rows alone do not prove no inbox reads or rolled-back writes. Add an interpreter/instrumented test that fails on inbox operations, or a dedicated database role lacking all inbox-table privileges while retaining downstream permissions. Run delegated intake successfully through it. The wrapper-only test must also succeed without Store.

Acceptance is the focused suite and complete `cabal test keiro-test` passing, with evidence recorded here. Fixtures clean up only their own temporary database state.


### Milestone 4 — Versioned DSL mode and current diff infrastructure


Add `IdempotenceMode = IdemInboxTable | IdemDelegated` and strict `idempotence :: IdempotenceMode` to `IntakeNode`. Update all construction, normalization, generators, and equality fixtures, including `Frontend/Internal.hs`, under the existing NoFieldSelectors convention.

At this baseline register candidate language 6 with predecessor 5, new syntax profile including `DelegatedInboxSyntax`, and an explicit runtime capability/profile for delegated intake generation. Preserve the predecessor aggregate-fold fingerprint segment because inbox routing changes no aggregate fold. If another plan has already opened a candidate when implementation starts, extend that candidate rather than allocate a competing version. Do not relabel any published language or rewrite historical fixtures.

Thread the frontend language context to `pIntake` in `Parser/Integration.hs` through `Parser/Document.hs`. Parse optional `idempotence table|delegated` immediately after dedupe and before optional `persist`. Claim the clause with the existing located feature-gate helper. These are contextual tokens, never additions to the global reserved-word list. Omission normalizes to table mode in every version; published versions reject the explicit new clause. PrettyPrint omits the default table clause, retaining historical rendering, and emits delegated explicitly. Candidate skeletons may show the table clause/comment; published skeletons remain unchanged.

Delegated mode creates no persisted envelope. Reject explicit `persist = dedupe-only` with a clear validator diagnostic because it suggests storage that does not exist; default/full persistence is accepted but documented as inapplicable. Keep all seven disposition rows and failure detail attachment. `inProgress` is never emitted by the new wrappers; `previouslyFailed` is reachable in retry mode and must not be labelled unreachable.

In `Scaffold.hs`, make generation consult the checked mode. For delegated intake emit `inboxIdempotence = IdempotenceDelegated`, `inboxDedupePolicy`, the existing service-specific outcome/disposition types, and a signed `runInboxIntake` wrapper partially applying `runInboxDelegated` to the generated policy. It takes metrics, event, optional Kafka metadata, and the delegated handler. Omit `inboxPersistence` from this new delegated surface and explain why. Keep published table output byte-compatible; a table-mode new-language module may export `inboxIdempotence = IdempotenceInboxTable` without changing the existing transaction handler contract. Register generated names/imports in the existing collision and manifest machinery.

Extend `intakePairDiff` rather than adding another intake walk. Retain `DedupeIdentityChanged` for key/policy changes and add only `IntakeIdempotenceModeChanged` for mode flips. Register it as `DiffDiagnostic` in `Validate.hs` and as persisted-identity context in both `Diff.hs` and `DiffReport.hs`, so compatibility vectors and CLI gates agree. Preserve addition/removal, decode, and persistence behavior. Both mode directions are breaking because their durable dedupe histories differ.

Acceptance: `keiro-dsl-test` proves candidate parsing and pretty round trips, exact predecessor rejection, unchanged historical generated bytes, normalization survival, invalid persistence diagnostics, exhaustive dispositions, diff code/vector/remedy classification, and a mode-change CLI test failing specifically on `--gate persisted-identity`. Use checked source/service APIs in tests; do not introduce bare-Spec shortcuts around source provenance.


### Milestone 5 — Real generated conformance


Add a dedicated candidate fixture `keiro-dsl/test/fixtures/intake-delegated.keiro` and generated/Hole integration under `keiro-dsl/test/conformance-intake-delegated/`, registered as `keiro-dsl-conformance-intake-delegated` in `keiro-dsl/keiro-dsl.cabal`. Keep the current table conformance suites as published-language evidence.

Generate source from the fixture into a temporary directory, compare it byte-for-byte to the committed generated layer, and compile through the generated manifest's edition defaults. A hand-filled integration imports generated `runInboxIntake`, uses `delegatedEventId` with envelope source and the stable target/operation name, invokes `delegatedCommand`, and explicitly handles its typed errors. Use the actual resource/error interpreter stack for SQL command callbacks. Add a live two-delivery test proving generated runner, duplicate classification, disposition, and durable effects together.

Update the conformance language-ownership inventory and record-migration inventory through their existing scripts as required. Do not regenerate unrelated released corpora. Acceptance: the dedicated suite, existing intake suites, `cabal test keiro-dsl:tests`, and generated/record/conformance policy targets all pass.


### Milestone 6 — Performance evidence, documentation, and durable decisions


Keep existing `keiro/bench/Main.hs` inbox scenarios and their baseline meanings. Add separately named `inbox.delegated-single`, `inbox.delegated-batch-100`, and matched `inbox.table-downstream-single`/`inbox.table-downstream-batch-100` comparators. Both modes perform the same downstream business write and duplicate check. The table version places that work and inbox insert in one transaction; delegated performs only downstream work. Do not change `single-nometrics` to a different workload under its historical name.

Measure fresh traffic, repeated-key traffic, and all-duplicate traffic, with metrics both off and on. Include one, 100, and 1,000 delivery chunks and a real aggregate duplicate case with 10, 1,000, and 100,000 historical events. A confirmed duplicate must use one indexed existence probe and zero command hydrations, appends, or inbox queries, independent of stream length. Fresh aggregate intake has one preflight plus the normal command work; matching/missing duplicate append errors allow one additional confirmation lookup. Verify SQL plans with `EXPLAIN (ANALYZE, BUFFERS)` in the isolated benchmark database to rule out a full stream scan.

Report time per delivery, deliveries/second, allocations per delivery, and peak residency for chunk sizes, with at least five paired serial runs and medians/ranges. Keep setup, ID generation, reset, and duplicate prepopulation outside the measured operation for new scenarios; report separately if the harness cannot exclude them. All runs use equivalent payloads, durability settings, connection pool, metrics, and downstream writes. Record GHC/package versions, PostgreSQL settings, hardware, and raw CSV locations.

Require no more than 10% median wrapper overhead versus an equivalent sequential direct-handler loop, and no more than 10% regression for untouched table scenarios on the same machine; investigate repeatable failures instead of updating a baseline to pass. Memory must scale with the caller's chunk, never total backlog or stream length. A delegated batch has up to one downstream transaction per unsuppressed item and therefore may lose to the table batch's shared commit. Record that crossover and explicitly recommend table batching where measured throughput is better. This is a measured selection criterion, not a promise that delegation always wins.

Use a clone-local candidate baseline only after the old table comparisons pass; retain raw old/new evidence before adding new scenario rows to `keiro/bench/baseline-inbox.csv`. No baseline refresh excuses a regression. Retain the project's 25% manual guard as an additional broad check.

Update `docs/user/integration-events.md`, `docs/guides/integration-events-with-kafka.md`, and `docs/corpus/keiro-dsl-corpus.md` with the delegation contract, command adapter, language version, retry ownership, throughput tradeoff, and lack of inbox backlog/dead-letter visibility. Explain that callers must durably publish a DLQ record before acknowledging a terminal failure; these wrappers do not do so.

Distill implemented decisions into a new or existing ADR using the profiled `docs/adr` contract, allocation tooling, and strict validation; update language ADR context only when that change actually lands. Update user-document timestamps/logs through the declared profile workflow. Acceptance: full Haskell verification, documentation/ADR/policy checks, and recorded performance evidence pass.


## Concrete Steps


Run from the repository root with its normal development environment. PostgreSQL tests start an isolated server through the fixture; they require PostgreSQL executables available on PATH. Use `nix develop` if the checkout's tools are not already available. Never inspect dependency code in the Nix store.

```bash
git status --short
mori registry search kiroku
mori registry show shinzui/kiroku --full
mori registry docs shinzui/kiroku
cabal build keiro keiro-dsl
cabal test keiro-test --test-options='--match "Keiro.Inbox delegated"'
cabal test keiro-test
cabal test keiro-dsl-test
cabal test keiro-dsl-conformance-intake-delegated
cabal test keiro-dsl:tests
```

The delegated suite/fixture commands become available in their milestones. Expected test completion includes `0 failures` and `Test suite ...: PASS`. Before selecting any new dependency bound, verify the released package against its authoritative registry and upstream release tags after Mori discovery; this plan requires no bound change.

Candidate CLI and generation proof:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/intake-delegated.keiro
cabal run keiro-dsl -- pretty keiro-dsl/test/fixtures/intake-delegated.keiro
delegated_scaffold_dir=$(mktemp -d /tmp/keiro-inbox-scaffold.XXXXXX)
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/intake-delegated.keiro --out "$delegated_scaffold_dir"
```

The check exits zero, pretty retains delegated mode and source version, and scaffold emits the typed runner. Implement the breaking-diff smoke test in the CLI test harness with a disposable Git repository: commit the same candidate spec in table mode, change only its idempotence clause, then invoke `keiro-dsl diff intake.keiro --since HEAD --gate persisted-identity` there. It must exit nonzero with `IntakeIdempotenceModeChanged`; an unchanged source exits zero. This avoids meaningless `HEAD~1` comparisons or tests that fail only because a fixture did not exist historically.

Benchmark and final validation:

```bash
cabal bench keiro-bench --benchmark-options="-p inbox -j1 --time-mode wall --csv bench-after-inbox.csv"
just bench-regression
just haskell-verify
just extension-policy
just dsl-api-boundaries
just record-migration-policy
just generated-name-policy
just conformance-corpus-policy
just user-documentation-validate
just adr-validate
```

Cabal runs the benchmark from `keiro/`, so the CSV is `keiro/bench-after-inbox.csv`. Archive named paired runs rather than overwriting evidence. The full manual benchmark guard includes other subsystem groups and may take longer than the focused inbox run.

Implementation commits use Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md
Intention: intention_01kwganm3be0q8z4g6rmcqdj05
```


## Validation and Acceptance


Acceptance requires the complete operation to have one committed effect after sequential replay, concurrent delivery, and loss of acknowledgement, with confirmed duplicates avoiding hydration and all inbox access. A failure, no-event command, unrelated event-ID collision, or mere workflow-instance existence must never be acknowledged as delegated success by a convenience adapter.

Batch tests must prove failure-then-repeat execution, source-scoped suppression, stable ordering, poison isolation, cancellation propagation, and metrics per classification. Retry tests must distinguish current invocation counts from durable caller bookkeeping. A no-Store wrapper test and denied/instrumented inbox access complement the empty-row assertion.

The candidate DSL must preserve published parser/generator contracts and emit a callable delegated runner. Mode changes must be breaking on the persisted-identity axis, while existing key/policy diagnostics stay intact. Generated output must be reproduced by the tool, compiled under its manifest contract, and exercised against the runtime.

Performance is accepted only with the M6 operation-count, memory-scaling, historical-regression, and paired measurement evidence. A slower batch comparison is a documented usage limitation, not permission to hide commit costs or claim a universal win. No benchmark or runtime acceptance has been executed during this plan-only revision.


## Idempotence and Recovery


The implementation adds no production schema or migration. Repeat tests in fresh fixture databases and regenerate only disposable or generator-owned outputs. Preserve hand-owned source and obey scaffold preflight/adoption checks; do not assume every generated file can be overwritten unconditionally.

Switching an existing consumer between table and delegated modes is not automatically safe. Old inbox rows do not imply downstream marker IDs exist, and delegated completions create no inbox history for a rollback. Drain in-flight work and establish an explicit cutover/replay boundary or a separately designed receipt migration before either switch. Merely reverting code may replay effects. Target deletion, relinking, changed source/consumer/operation naming, and dropping marker events can also invalidate the dedupe contract; retain identities and durable evidence for the full delivery/replay horizon.

If a delegated batch is interrupted after some commits, redeliver unacknowledged input; downstream identity checks must absorb completed items. Do not resume by trusting the discarded in-memory set. Retrying external effects without their own idempotence key is outside this API.


## Interfaces and Dependencies


These are proposed APIs, not existing exports. Keep the wrappers' metrics implementation shared with the current inbox code. No new external package or dependency bound is required.

```haskell
-- Keiro.Inbox.Types
data DelegatedOutcome a = DelegatedFresh !a | DelegatedDuplicate
data InboxIdempotence = IdempotenceInboxTable | IdempotenceDelegated

-- Export the type abstractly; constructor validates both positive values.
mkDelegatedRetryContext :: Int -> Int -> Either Text DelegatedRetryContext

-- Keiro.Inbox
runInboxDelegated ::
  IOE :> es =>
  Maybe KeiroMetrics -> InboxDedupePolicy ->
  IntegrationEvent -> Maybe KafkaDeliveryRef ->
  (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
  Eff es (Either InboxError (InboxResult a))

runInboxDelegatedWithRetries ::
  IOE :> es =>
  Maybe KeiroMetrics -> DelegatedRetryContext -> InboxDedupePolicy ->
  IntegrationEvent -> Maybe KafkaDeliveryRef ->
  (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
  Eff es (Either InboxError (InboxResult a))

runInboxDelegatedBatch ::
  IOE :> es =>
  Maybe KeiroMetrics -> InboxDedupePolicy ->
  [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
  (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
  Eff es [Either InboxError (InboxResult a)]

-- Keiro.Inbox.Delegated
delegatedEventId ::
  Text -> Text -> Text -> StreamName -> Text -> EventId

data DelegatedCommandError
  = DelegatedCommandFailed !StreamName !CommandError
  | DelegatedCommandWithoutReceipt !StreamName

delegatedCommand ::
  Store :> es =>
  RunCommandOptions -> StreamName -> EventId ->
  (RunCommandOptions -> Eff es (Either CommandError (CommandResult target))) ->
  Eff es (Either DelegatedCommandError (DelegatedOutcome (CommandResult target)))

delegatedFromPMCommand ::
  StreamName ->
  PMCommandResult target ->
  Either DelegatedCommandError (DelegatedOutcome (CommandResult target))
```

The PM adapter takes the resolved target stream name for reporting a zero-event result; `CommandResult.target` is a typed stream reference, not necessarily its resolved store name. A `PMCommandFailed` retains the stream name carried by that failure.

The generated delegated `runInboxIntake` has the `runInboxDelegated` signature with the policy argument removed. It preserves the polymorphic effect stack and does not require Store; the integration's command callback supplies its own additional effects. No generic workflow-start API is introduced.

Revision note (2026-09-15): Replaced the July design with the current runtime/DSL baseline; corrected duplicate confirmation, no-op/failed-command handling, workflow guarantees, source/target identity encoding, retry semantics, and batch safety. Added published-language gating, generated runner conformance, explicit cutover risks, and measurable performance gates. Feature implementation remains pending.

Revision note (2026-09-15): Recorded completion of Milestone 1 and the implemented portion of Milestone 2, including focused and full runtime validation evidence. Documented the abstract retry-context accessor decision and the exact remaining adapter proof.

Revision note (2026-09-15): Recorded completion of Milestone 2 and the focused durable evidence for Milestone 3. Added the observed concurrent-race classification and retained the denied-inbox-privilege/full-suite checks as explicit remaining work.

Revision note (2026-09-15): Recorded completion of Milestone 3 after the restricted-role proof and the 694-example complete runtime suite passed.
