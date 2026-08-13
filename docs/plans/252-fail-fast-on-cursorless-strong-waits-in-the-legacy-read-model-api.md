---
id: 252
slug: fail-fast-on-cursorless-strong-waits-in-the-legacy-read-model-api
title: "Fail fast on cursorless strong waits in the legacy read-model API"
kind: exec-plan
created_at: 2026-08-12T23:55:43Z
intention: "intention_01kzw6dkcserms9yr61sqdntep"
master_plan: "docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md"
---

# Fail fast on cursorless strong waits in the legacy read-model API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The module header of `keiro/src/Keiro/ReadModel.hs` promises: "Waiting modes require
'DurableQueryCursor'; a cursorless model fails with 'ReadModelMissingCursor' before
polling." Today that promise is only true for `runQuery` and `runQueryWithFreshness`. Two
other public paths read the model's legacy `subscriptionName` field raw: the exported,
non-deprecated `waitFor`, and the deprecated `runQueryWith` when given a waiting override
(`Strong`, or `PositionWait` with a target). On a cursorless model — one built with
`immediateReadModel` and `cursorAuthority = NoQueryCursor` — that raw field holds an
internal sentinel string, so those paths poll a subscription that can never exist, burn
the entire wait timeout (five seconds by default), increment the
`keiro.projection.wait.timeouts` metric as if a real projection had fallen behind, and
finally return `ReadModelWaitTimeout` with a last-observed position of zero. The truthful
`runQueryWithFreshness` on the very same model fails in microseconds with the typed
`ReadModelMissingCursor`.

A third path crosses the same capability boundary incorrectly:
`Keiro.ReadModel.Rebuild.startRebuild` sends the private sentinel to Kiroku as a
subscription name even though a cursorless model has no checkpoint to reset. A
planning-time PostgreSQL `convert_from` probe rejected the sentinel's leading NUL byte
with error 22021, but the Milestone 1 database regression showed that the actual Hasql
`text[]` parameter path accepts it and the lifecycle completes. The reset request is
still invalid at the type and ownership boundary and exposes private compatibility
storage to a dependency. Generated Language-5 scaffolds pair cursorless read models with
a `startXxxRebuild` helper that calls exactly this function, so the runtime must define
the no-cursor lifecycle explicitly.

After this plan, every public wait path on a cursorless model fails fast with the same
typed `ReadModelMissingCursor` that `runQueryWithFreshness` raises, records no spurious
timeout metric, and returns well under the timeout; and `startRebuild` on a cursorless
model completes its fence/truncate lifecycle, explicitly skipping the checkpoint reset
because there is no cursor to reset. Behavior for every model that carries a real cursor
— including every directly constructed 0.11 record — is unchanged, preserving the
compatibility contract pinned by
`docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md`.
You can see it working by running the three new tests in `cabal test keiro-test`: before
the fix, the two wait examples burn five-second timeouts while the rebuild lifecycle
already completes through the current driver; after the fix, all three pass in under a
second and the rebuild implementation no longer issues a reset for `NoQueryCursor`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: added the three cursorless regression tests and rebuild fixture; `cabal build
  keiro-test` passed, and the direct matched run finished in 10.5104 seconds with three
  examples, two expected wait failures, and the rebuild example unexpectedly green.
- [x] M2: routed `waitFor` through the cursor-authority check, translated
  `runQueryWith` onto `runQueryWithFreshness`, deleted `waitIfNeeded`, and updated the
  module/function/error Haddocks.
- [x] M2: `cabal build all` and `cabal build keiro-test` passed; the three cursorless
  examples passed in 0.4572 seconds and the full `Keiro.ReadModel` group passed 33
  examples in 16.4079 seconds, including the 0.11 compatibility fixture at build time.
- [x] M3: `startRebuild` now skips checkpoint reset for `NoQueryCursor` through the
  typed decoder and documents the branch; both cursorless and cursor-bearing rebuild
  examples passed in the 33-example read-model group.
- [x] M3: audited `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`; inline ownership resolves to
  `NoQueryCursor`, unmanaged cursorless lifecycle helpers pass `[]`, and no generated
  test module currently combines `NoQueryCursor` with `Rebuild.startRebuild`.
- [x] M4: updated `docs/user/read-models-and-projections.md`,
  `docs/user/api-reference.md`, and `keiro/CHANGELOG.md` with the verified fail-fast
  and typed cursorless rebuild contracts.
- [ ] M4: run `cabal test keiro-test` in full, then `just verify`; record results; update
  the MasterPlan 40 registry row for this plan; complete the living sections and the ADR
  distillation pass (expected outcome: no ADR change — see Decision Log).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The planning-time `convert_from` probe did not predict the actual Hasql parameter path:
  before the runtime fix, the cursorless `startRebuild` regression already passed. The
  NUL-prefixed sentinel sent through Kiroku's encoded `text[]` reset did not abort this
  PostgreSQL-backed test, while both raw wait paths failed exactly as predicted.

  Evidence from the direct `--match cursorless` run:

  ```text
  waitFor fails fast on a cursorless model instead of burning the timeout [✘]
  deprecated Strong and PositionWait overrides fail fast on a cursorless model [✘]
  startRebuild on a cursorless model skips the checkpoint reset and completes [✔]
  Finished in 10.5104 seconds
  3 examples, 2 failures
  ```

  The rebuild fix remains warranted as a typed capability boundary: a
  `NoQueryCursor` model has no checkpoint to reset, so `startRebuild` must not pass its
  private compatibility sentinel to the owning library even when the current driver and
  server accept that encoded parameter.

- The scaffold audit confirmed no generated-byte change is needed. `ownerDerivedCursor`
  returns `Nothing` for an inline owner, the truthful definition renders that as
  `NoQueryCursor`, and `legacyReadModelFeed` renders its projection-name list as `[]`.
  Of the 16 files under `keiro-dsl/test/` containing `Rebuild.startRebuild`, only
  `keiro-dsl/test/Main.hs` also contains `NoQueryCursor`; no generated `ReadModel.hs`
  module contains both tokens.


## Decision Log

Record every decision made while working on the plan.

- Decision: Fix the deprecated `runQueryWith` by translating its `ConsistencyMode` into
  the exact `QueryFreshness` it already denotes and delegating to the truthful execution
  path, rather than patching a sentinel check into the legacy wait helper.
  Rationale: `runQuery` already executes legacy defaults through exactly this translation
  (`readModelDefaultFreshness`), so the deprecated override becomes the one remaining
  consumer of a parallel wait path; unifying them makes a cursorless `Strong` override
  return the identical `ReadModelMissingCursor (WaitForHead scope)` payload that
  `runQueryWithFreshness` returns on the same model, and makes future divergence
  impossible. For cursor-bearing models the two paths were already observably identical
  (`defaultStrongWaitOptions` is defined as `defaultHeadWaitOptions`; both end in
  `waitForCursor` with the same options), so plan 244's 0.11 compatibility window is
  preserved exactly.
  Date: 2026-08-12
- Decision: `waitFor` reports its missing-cursor error as
  `ReadModelMissingCursor name (WaitForPosition (options & #target ?~ targetPosition))`,
  injecting the concrete target into the options it echoes back.
  Rationale: `waitFor`'s requested operation is a position wait; its `options.target`
  field is frequently `Nothing` at the call boundary because the target arrives as a
  separate argument, and echoing a `Nothing` target would misread as a missing-position
  problem. Injecting the target makes the error self-describing and deterministic for
  tests.
  Date: 2026-08-12
- Decision: `startRebuild` on a cursorless model skips the subscription-checkpoint reset
  (an explicit `NoQueryCursor` branch decided by the typed `readModelCursorAuthority`
  decoder) rather than refusing the rebuild.
  Rationale: the unmanaged single-model rebuild lifecycle explicitly supports inline-only
  models — `finishRebuild` documents and implements the empty-projection-name exemption
  for exactly that shape — and Language-5 scaffolds generate `startRebuild` calls for
  cursorless models. There is genuinely no cursor to reset, so a skip is the semantically
  correct action, not error suppression. The planning-time `convert_from` probe suggested
  PostgreSQL error 22021, but the actual Hasql regression accepted the encoded parameter;
  the fix therefore repairs an invalid dependency request and makes the capability
  contract explicit rather than claiming a reproduced transaction failure. The typed
  acknowledgment lives in the code branch on `QueryCursorAuthority` and in the function's
  documented contract; the signature is unchanged because the skip is not an error
  condition a caller must handle.
  Date: 2026-08-12
- Decision: Retract the planning claim that the current Hasql rebuild path aborts on the
  sentinel; document and changelog the verified defect as an unnecessary reset request
  that leaks private cursorless representation across the Kiroku boundary.
  Rationale: the direct PostgreSQL `convert_from` probe raised SQLSTATE 22021, but the
  pre-fix database-backed `startRebuild` example passed. Operator-facing text must follow
  executable evidence while the typed `NoQueryCursor` branch still enforces the correct
  no-checkpoint semantics.
  Date: 2026-08-13
- Decision: No ADR is amended or created by this plan.
  Rationale: `docs/adr/0033-consistency-waits-target-reachable-visible-heads.md` governs
  what position a wait targets; this plan changes which models may wait at all, which is
  the missing-cursor capability contract plan 244 already documented for the truthful
  API — this plan extends it to the remaining public paths without changing it. The
  `startRebuild` skip does not alter the checkpoint-reset contract for cursor-bearing
  models (Kiroku's reset semantics under
  `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` are untouched) and does not change any
  durable boundary; it makes the existing documented lifecycle actually executable for a
  model shape that has no checkpoint. If implementation reveals a durable contract change
  after all, revisit this decision and amend ADR 0033 or create a new ADR in the same
  change.
  Date: 2026-08-12
- Decision: The sentinel-carrying model shape is outside plan 244's byte-for-byte 0.11
  compatibility guarantee, so failing fast on it via the deprecated paths is a bug fix,
  not a compatibility break.
  Rationale: the sentinel is a private NUL-prefixed string introduced by plan 244's
  builders; no 0.11 code can construct it (plan 244's Surprises log notes it "cannot be
  persisted as a PostgreSQL text subscription name" by design). Every model reachable
  from 0.11 source carries a real subscription name and keeps identical behavior, which
  the existing legacy/truthful equivalence tests in `keiro/test/Main.hs` continue to
  prove.
  Date: 2026-08-12


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The repository is the `keiro` multi-package Haskell project (root:
`/Users/shinzui/Keikaku/bokuno/keiro`). Everything this plan touches lives in the `keiro`
package (runtime library) and its test suite; one audit step reads, but does not change,
`keiro-dsl`.

A *read model* (`ReadModel q r` in `keiro/src/Keiro/ReadModel.hs`) is a named, versioned
SQL projection table plus the query that reads it. A *projection* keeps that table up to
date from the event log; an asynchronous projection tracks its progress with a durable
*subscription checkpoint* (a row in Kiroku's `subscriptions` table, keyed by subscription
name). Querying a read model can optionally *wait* for that checkpoint to reach a target
event-log position ("freshness") before running the SQL.

Two API generations coexist during the 0.12 compatibility window, established by
`docs/plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md`:

- The truthful surface: `ReadModelBlueprint` with `cursorAuthority ::
  QueryCursorAuthority` (`NoQueryCursor` or `DurableQueryCursor name`), builders
  (`immediateReadModel`, `headWaitingReadModel`, `positionWaitingReadModel`), freshness
  values (`Immediate`, `WaitForHead`, `WaitForPosition`), and `runQueryWithFreshness`.
- The deprecated 0.11 surface, removed in 0.13: the raw `ReadModel` record with a
  mandatory `subscriptionName :: Text` field, `ConsistencyMode`
  (`Strong`/`Eventual`/`PositionWait`), and `runQueryWith`.

Because the physical `ReadModel` record could not gain a field without breaking 0.11
positional construction, the builders encode cursor absence in the mandatory
`subscriptionName` field using a private sentinel. In `keiro/src/Keiro/ReadModel.hs`:

```haskell
noQueryCursorSentinel :: Text
noQueryCursorSentinel = "\NULkeiro:no-query-cursor"
```

`blueprintReadModel` writes it via `cursorText` when the blueprint says `NoQueryCursor`,
and the exported decoder `readModelCursorAuthority` is the single sanctioned way to read
it back: it returns `NoQueryCursor` when the field equals the sentinel and
`DurableQueryCursor` otherwise. The truthful execution path honors this: every waiting
freshness goes through the internal helper `withCursor` (near the bottom of the module),
which calls `readModelCursorAuthority` and returns
`Left (ReadModelMissingCursor name requestedFreshness)` for a cursorless model before any
polling. This is the "internal predicate" the fix must reuse; do not compare against the
sentinel literal anywhere else, and do not duplicate the literal.

### Defect one: the raw wait paths

Three functions in `keiro/src/Keiro/ReadModel.hs` matter here (all near lines 400-530):

- `waitFor` (exported, not deprecated) takes `PositionWaitOptions`, a `ReadModel`, and a
  target `GlobalPosition`, and today passes `readModel ^. #subscriptionName` — raw, no
  decoding — to the internal poll loop `waitForCursor`.
- `waitIfNeeded` (private) implements the deprecated `runQueryWith` override: `Strong`
  captures a visible head (per the record's `strongScope`) and calls `waitFor`;
  `PositionWait` with a `Just` target calls `waitFor`; `Eventual` and target-less
  `PositionWait` return immediately.
- `waitForCursor` polls `readSubscriptionPosition cursor` every `pollMicros` (10ms
  default) until the checkpoint reaches the target or `timeoutMicros` (five seconds
  default) elapses, at which point it calls `recordProjectionWaitTimeouts metrics 1`
  (the `keiro.projection.wait.timeouts` counter, defined in
  `keiro/src/Keiro/Telemetry.hs`) and returns `ReadModelWaitTimeout name target observed`.

The poll never errors on the sentinel because `readSubscriptionPosition` fetches Kiroku's
whole checkpoint inventory and filters it client-side in Haskell
(`subscriptionPositionFromInventory`); the sentinel never reaches the wire, it simply
never matches, so `observed` stays `GlobalPosition 0` forever. Consequence: on a
cursorless model, `waitFor` and any waiting `runQueryWith` override poll for the full
timeout, bump a metric documented as "position-wait calls that timed out before the
projection caught up" (no projection exists to catch up), and return
`ReadModelWaitTimeout name target (GlobalPosition 0)` — while `runQueryWithFreshness` on
the same model returns `ReadModelMissingCursor` immediately. `runQuery` (the default
path) is already safe: it translates the legacy record through
`readModelDefaultFreshness` and executes via `runQueryWithFreshness`.

The behavior was introduced with the plan-244 compatibility layer (commits `d058e801`
and `4eae4796`, `feat(read-model): add truthful freshness facade` / `execute truthful
freshness waits`): the truthful path got the `withCursor` guard, the legacy path kept the
raw field read.

### Defect two: the rebuild checkpoint reset

`startRebuild` in `keiro/src/Keiro/ReadModel/Rebuild.hs` (near line 128) is the unmanaged
single-read-model rebuild entry point: in one transaction it marks the model `Rebuilding`
(taking the writer-fence row lock), truncates the data table, deletes the named
projections' dedup keys, and calls Kiroku's `resetSubscriptionCheckpointsTx` with
`SubscriptionName (readModel ^. #subscriptionName)` — again the raw field. Kiroku's reset
(see `Kiroku.Store.Subscription.Checkpoint` in the `kiroku-store` package,
`mori://shinzui/kiroku/packages/kiroku-store`) never creates rows for missing names, so
the names as a `text[]` parameter through `unnest`. A planning-time probe suggested that
the sentinel could not traverse that boundary:

```text
postgres=# SELECT s.* FROM subs s
           JOIN unnest(ARRAY[convert_from('\x006b6569726f'::bytea,'UTF8')]) r(n)
             ON s.subscription_name = r.n;
ERROR:  22021: invalid byte sequence for encoding "UTF8": 0x00
```

The actual database-backed Milestone 1 regression contradicted that prediction: the
Hasql-encoded parameter was accepted and the full lifecycle passed before the branch was
added. The defect is therefore not a reproduced transaction abort on this toolchain; it
is the raw reset request itself. A cursorless model has no checkpoint, and its private
compatibility sentinel must not cross into Kiroku as though it were a durable
subscription identity. This matters because generated code creates exactly this pairing:
in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, `emitReadModelGenWithContract` (near line 4637)
emits a blueprint with `cursorAuthority = NoQueryCursor` (near line 4732) whenever the
resolved owner-derived cursor is absent (owner delivery is inline — see
`ownerDerivedCursor`, near line 4099), and for any model without a catalog group it also
emits the legacy lifecycle helpers including `startXxxRebuild = Rebuild.startRebuild
<model> <projectionNames>` (near line 4764). For such inline-supplied models the emitted
projection-name list is `[]`, which `finishRebuild` explicitly documents as the
inline-only shape exempt from its empty-rebuild guard — evidence that cursorless rebuilds
are an intended, supported operation and that reset must be skipped explicitly.

### The test suite

Database-backed tests live in `keiro/test/Main.hs` (test-suite `keiro-test`). The suite
uses the suite-level *template-database fixture* from `keiro-test-support`: `main =
withMigratedSuite $ \fixture -> ...` migrates one template database once; each example
wrapped by `around (withFreshStore fixture)` gets a fresh database cloned from that
template in milliseconds. Never add per-example migrations. The relevant `describe
"Keiro.ReadModel"` block starts near line 3130 and already contains the fixtures this
plan reuses:

- `counterImmediateReadModel` (near line 14704): a cursorless model,
  `immediateReadModel (counterReadModelBlueprint NoQueryCursor)`, registry name
  `"counter-read-model"`.
- `counterReadModel` / `counterCursorReadModel`: cursor-bearing legacy and blueprint
  variants on the subscription `"counter-read-model-sub"`.
- `initializeRegisteredReadModel`, `initializeCounterReadModelTable`,
  `upsertSubscriptionCursorStmt`, `fastWaitOptions` (50ms timeout, 5ms poll).
- A metrics-assertion pattern (near line 3973, "counts a position-wait timeout in the
  timeout counter"): `inMemoryMetricExporter` + `createMeterProvider` + `getMeter` +
  `Telemetry.newKeiroMetrics`, then `forceFlushMeterProvider` and
  `flattenScalarPoints` to look up `"keiro.projection.wait.timeouts"`.
- Rebuild runbook tests (near line 3700) showing the `Rebuild.startRebuild` /
  `finishRebuild` call shape and asserting the checkpoint reset for cursored models.

The compile-only fixture `keiro/test/Compatibility/ReadModel011.hs` pins 0.11 source
compatibility (direct records, positional construction, all legacy constructors,
`runQueryWith`); it must keep compiling unchanged.

### Relevant ADRs

- `docs/adr/0033-consistency-waits-target-reachable-visible-heads.md`: a wait target
  must be reachable by the observed consumer; `Strong`/`WaitForHead` capture the newest
  *visible* head. This plan does not change wait targets, only which models may wait at
  all; per the scope judgment recorded in the Decision Log, no amendment is expected.
- `docs/adr/0031-subscription-checkpoint-policy-is-catalog-identity-and-replay-safety.md`:
  Kiroku owns checkpoint rows and their reset semantics. The `startRebuild` fix keeps
  using Kiroku's public reset for cursor-bearing models and simply stops asking Kiroku to
  reset a cursor that does not exist.
- Cross-repository: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-4` owns checkpoint
  initialization, monotonic saves, and explicit reset; this plan does not touch those
  semantics. No other cross-repository ADR bears on this work.

Coordination context from the parent MasterPlan
(`docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md`):
this is EP-3; no sibling plan touches `keiro/src/Keiro/ReadModel.hs` or
`keiro/src/Keiro/ReadModel/Rebuild.hs`, so there is no file-level coordination. MasterPlan
41 (out-of-process read-model consumers) consumes the freshness vocabulary only through
documented APIs; making the documented missing-cursor contract hold on every path
strengthens what it builds on. This plan gates the 0.12.0.0 release.


## Plan of Work

### Milestone 1 — Reproduce all three defects with failing tests

Scope: add three tests to the `describe "Keiro.ReadModel"` block in
`keiro/test/Main.hs` and one fixture near the existing read-model fixtures (around line
14700). At the end of this milestone the tests exist, compile, and fail for the exact
reasons the defect predicts; nothing in `src/` has changed. Include the word
"cursorless" in each `it` string so one hspec `--match` selects all three. Commit the red
tests together with the Milestone 2 work (the suite must not be left red on its own
commit) or as a separate commit immediately followed by the fix commits — follow the
repository's existing practice of committing red tests only alongside or immediately
before their fix.

First test — `waitFor` fails fast. `waitFor` performs no registry validation, so no
registration is needed. Build the metrics harness exactly like the existing
"counts a position-wait timeout in the timeout counter" example, then:

```haskell
it "waitFor fails fast on a cursorless model instead of burning the timeout" $ \storeHandle -> do
  (exporter, metricsRef) <- inMemoryMetricExporter
  (provider, _env) <-
    createMeterProvider
      emptyMaterializedResources
      defaultSdkMeterProviderOptions {metricExporter = Just exporter}
  meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
  keiroMetrics <- Telemetry.newKeiroMetrics meter
  startedAt <- getCurrentTime
  waitResult <-
    Store.runStoreIO storeHandle $
      waitFor (Just keiroMetrics) defaultHeadWaitOptions counterImmediateReadModel (GlobalPosition 5)
  finishedAt <- getCurrentTime
  waitResult
    `shouldBe` Right
      ( Left
          ( ReadModelMissingCursor
              "counter-read-model"
              (WaitForPosition (defaultHeadWaitOptions & #target ?~ GlobalPosition 5))
          )
      )
  -- Well under the five-second timeout: this is a capability check, not a poll.
  diffUTCTime finishedAt startedAt `shouldSatisfy` (< 2)
  -- No spurious give-up: the timeout counter must not move for a cursorless model.
  _ <- forceFlushMeterProvider provider Nothing
  exported <- readIORef metricsRef
  lookup "keiro.projection.wait.timeouts" (flattenScalarPoints exported) `shouldBe` Nothing
```

Today this example takes about five seconds and fails on the first assertion with
`ReadModelWaitTimeout "counter-read-model" (GlobalPosition 5) (GlobalPosition 0)`; the
metric lookup would report `Just (IntNumber 1)`.

Second test — the deprecated waiting overrides fail fast. Register the cursorless model,
then append one event through `runCommand` so the visible store head is greater than
zero. This is essential for a genuine red test: on an empty log the captured head is
`GlobalPosition 0` and the current poll loop returns success immediately (the observed
position starts at zero), hiding the defect. Do not advance any subscription cursor.

```haskell
it "deprecated Strong and PositionWait overrides fail fast on a cursorless model" $ \storeHandle -> do
  (exporter, metricsRef) <- inMemoryMetricExporter
  (provider, _env) <-
    createMeterProvider
      emptyMaterializedResources
      defaultSdkMeterProviderOptions {metricExporter = Just exporter}
  meter <- getMeter provider Telemetry.keiroInstrumentationLibrary
  keiroMetrics <- Telemetry.newKeiroMetrics meter
  Right () <-
    Store.runStoreIO storeHandle $
      initializeRegisteredReadModel counterImmediateReadModel initializeCounterReadModelTable
  let target = stream "read-model-cursorless-strong" :: Stream CounterEventStream
  Right (Right _) <-
    Store.runStoreIO storeHandle $
      runCommand defaultRunCommandOptions counterEventStream target (Add 5)
  startedAt <- getCurrentTime
  strongResult <-
    Store.runStoreIO storeHandle $
      runQueryWith (Just keiroMetrics) Strong counterImmediateReadModel "inline"
  finishedAt <- getCurrentTime
  strongResult
    `shouldBe` Right
      (Left (ReadModelMissingCursor "counter-read-model" (WaitForHead EntireVisibleLog)))
  diffUTCTime finishedAt startedAt `shouldSatisfy` (< 2)
  -- The deprecated override and the truthful API agree exactly on this model.
  truthfulResult <-
    Store.runStoreIO storeHandle $
      runQueryWithFreshness Nothing (WaitForHead EntireVisibleLog) counterImmediateReadModel "inline"
  truthfulResult `shouldBe` strongResult
  positionResult <-
    Store.runStoreIO storeHandle $
      runQueryWith
        (Just keiroMetrics)
        (PositionWait (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
        counterImmediateReadModel
        "inline"
  positionResult
    `shouldBe` Right
      ( Left
          ( ReadModelMissingCursor
              "counter-read-model"
              (WaitForPosition (fastWaitOptions & #target .~ Just (GlobalPosition 5)))
          )
      )
  _ <- forceFlushMeterProvider provider Nothing
  exported <- readIORef metricsRef
  lookup "keiro.projection.wait.timeouts" (flattenScalarPoints exported) `shouldBe` Nothing
```

Today the `Strong` call burns five seconds and returns
`ReadModelWaitTimeout "counter-read-model" <visible head> (GlobalPosition 0)`, the parity
assertion fails (the truthful API returns the missing-cursor error), the `PositionWait`
call burns its 50ms timeout, and the metric holds `Just (IntNumber 2)`.

Third test — the cursorless rebuild lifecycle completes. Add one fixture next to the
existing ones. It must use `schema = "kiroku"` (unlike `counterImmediateReadModel`, whose
blueprint says `"public"`) because `startRebuild` truncates
`qualifiedTableName readModel` and the unqualified `CREATE TABLE` in
`initializeCounterReadModelTable` lands in the `kiroku` schema, where the existing
cursored rebuild tests already truncate it:

```haskell
-- A cursorless model whose qualified table matches where the counter test table
-- actually lives, so the rebuild lifecycle's TRUNCATE resolves.
counterCursorlessRebuildReadModel :: ReadModel Text Int
counterCursorlessRebuildReadModel =
  immediateReadModel ((counterReadModelBlueprint NoQueryCursor) & #schema .~ "kiroku")
```

Then the test, in the same describe block:

```haskell
it "startRebuild on a cursorless model skips the checkpoint reset and completes" $ \storeHandle -> do
  Right () <-
    Store.runStoreIO storeHandle $
      initializeRegisteredReadModel counterCursorlessRebuildReadModel initializeCounterReadModelTable
  -- Seed a stale row so the truncate is observable, and an unrelated durable
  -- checkpoint so we can prove the rebuild does not touch subscriptions.
  Right () <-
    Store.runStoreIO storeHandle $
      Store.runTransaction $ do
        Tx.sql "INSERT INTO counter_read_model (model_id, amount, last_seen) VALUES ('inline', 9, 1)"
        Tx.statement ("counter-read-model-sub", 7) upsertSubscriptionCursorStmt
  rebuildingResult <-
    Store.runStoreIO storeHandle $
      Rebuild.startRebuild counterCursorlessRebuildReadModel [] (GlobalPosition 0)
  rebuilding <- case rebuildingResult of
    Right metadata -> pure metadata
    Left err -> expectationFailure ("cursorless startRebuild failed: " <> show err) *> error "unreachable"
  rebuilding ^. #status `shouldBe` Rebuilding
  -- The unrelated checkpoint is untouched: no reset ran, silently or otherwise.
  untouched <-
    Store.runStoreIO storeHandle $
      readSubscriptionPosition "counter-read-model-sub"
  untouched `shouldBe` Right (Just (GlobalPosition 7))
  -- The inline-only exemption promotes an empty-projection-list rebuild.
  Right (Right live) <-
    Store.runStoreIO storeHandle $
      Rebuild.finishRebuild counterCursorlessRebuildReadModel [] (GlobalPosition 0)
  live ^. #status `shouldBe` Live
  -- The truncate happened: the seeded row is gone.
  afterRebuild <-
    Store.runStoreIO storeHandle $
      runQuery Nothing counterCursorlessRebuildReadModel "inline"
  afterRebuild `shouldBe` Right (Right 0)
```

Before the fix this example unexpectedly passes on the current Hasql/PostgreSQL path.
That result is recorded in Surprises & Discoveries. It remains the behavioral acceptance
for the supported cursorless lifecycle, while the Milestone 3 source change supplies the
typed proof that no reset is requested.

Acceptance for Milestone 1: `cabal build keiro-test` succeeds;
`cabal test keiro-test --test-option=--match --test-option="cursorless"` runs exactly the
three new examples: the first two fail after multi-second waits, and the rebuild example
passes. Record the observed transcript in this plan.

### Milestone 2 — Route every wait through the cursor-authority check

Scope: `keiro/src/Keiro/ReadModel.hs` only. At the end, the first two tests pass in
milliseconds, all existing read-model tests still pass, and the deprecated override is
implemented on top of the truthful path.

Edit one: reimplement `waitFor` through `withCursor`, keeping its exported signature.
Replace the current body (which passes `readModel ^. #subscriptionName` to
`waitForCursor`) with:

```haskell
waitFor metrics options readModel targetPosition =
  withCursor
    (WaitForPosition (options & #target ?~ targetPosition))
    readModel
    (\cursor -> waitForCursor metrics options readModel cursor targetPosition)
```

Update its Haddock to state the complete contract: blocks until the model's durable
cursor reaches the target, polling at `pollMicros`; returns `ReadModelWaitTimeout` on
timeout; and on a model without a durable cursor (`readModelCursorAuthority` returns
`NoQueryCursor`) fails fast with `ReadModelMissingCursor` — no polling, no timeout
metric.

Edit two: translate the deprecated override onto the truthful path. Add a private
translation that maps an explicit `ConsistencyMode` to the exact operational
`QueryFreshness`, reusing it from `readModelDefaultFreshness` so the two can never
disagree:

```haskell
-- | Translate a legacy consistency mode into the exact operational freshness.
-- The historical @PositionWait@ with no target is immediate. Strong resolves its
-- head scope from the model's compatibility 'strongScope' field.
legacyOverrideFreshness :: ConsistencyMode -> ReadModel q r -> QueryFreshness
legacyOverrideFreshness Strong readModel =
  WaitForHead (legacyHeadScope (readModel ^. #strongScope))
legacyOverrideFreshness Eventual _ = Immediate
legacyOverrideFreshness (PositionWait options) _ =
  case options ^. #target of
    Nothing -> Immediate
    Just _ -> WaitForPosition options

readModelDefaultFreshness :: ReadModel q r -> QueryFreshness
readModelDefaultFreshness readModel =
  legacyOverrideFreshness (readModel ^. #defaultConsistency) readModel
```

Then make `runQueryWith` delegate and delete `waitIfNeeded` entirely (its only caller is
`runQueryWith`; after this edit nothing references it and the module will not compile
until it is removed, by design):

```haskell
runQueryWith metrics consistency readModel =
  runQueryWithFreshness metrics (legacyOverrideFreshness consistency readModel) readModel
```

This is behavior-preserving for every cursor-bearing model: `Eventual` and target-less
`PositionWait` translate to `Immediate` (no wait, exactly as before); `Strong` translates
to `WaitForHead` with the same scope, and `waitForFreshness` captures the same head and
polls with `defaultHeadWaitOptions`, which is definitionally what `waitIfNeeded` used
(`defaultStrongWaitOptions = defaultHeadWaitOptions`); `PositionWait (Just p)` polls the
same cursor with the same options. The only observable change is on cursorless models,
where waiting overrides now return the same `ReadModelMissingCursor` payload as
`runQueryWithFreshness` — for `Strong`, that is `WaitForHead <scope>`, which is why the
second test's parity assertion holds. Deprecation pragmas need no changes: GHC does not
warn on deprecated identifiers used inside their defining module. Update the
`runQueryWith` Haddock to say the override is translated to its exact freshness and
executed truthfully, that waiting overrides on a cursorless model fail fast with
`ReadModelMissingCursor`, and that models with real cursors keep their exact 0.11
behavior. Extend the module-header paragraph to note the missing-cursor guarantee now
covers `waitFor` and the deprecated `runQueryWith` as well.

Acceptance for Milestone 2: the first two "cursorless" tests pass, each example
completing in well under two seconds; `cabal test keiro-test --test-option=--match
--test-option="Keiro.ReadModel"` passes in full, proving the legacy/truthful equivalence
examples ("Strong returns immediately...", "...still time out when visible events outrun
the subscription", the GC and category-scope proofs, the PositionWait examples, and the
timeout-counter example) observe no behavior change for cursor-bearing models; the
compile-only fixture `keiro/test/Compatibility/ReadModel011.hs` still compiles
(`cabal build keiro-test` covers it).

### Milestone 3 — Skip the checkpoint reset for cursorless rebuilds, and audit the scaffold pairing

Scope: `keiro/src/Keiro/ReadModel/Rebuild.hs`, plus a read-only audit of
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. At the end, the third test passes and the
generated-scaffold pairing is documented as safe.

In `startRebuild`, replace the unconditional reset with a typed branch on the same
decoder the query paths use (the module already imports `Keiro.ReadModel` unqualified, so
`readModelCursorAuthority` and `QueryCursorAuthority` are in scope):

```haskell
startRebuild readModel projectionNames replayFrom =
  runTransaction $ do
    metadata <- transitionReadModelTxFor readModel Rebuilding
    Tx.sql (TE.encodeUtf8 ("TRUNCATE TABLE " <> qualifiedTableName readModel))
    unless (null projectionNames) $
      Tx.statement projectionNames deleteProjectionDedupStmt
    case readModelCursorAuthority readModel of
      NoQueryCursor -> pure ()
      DurableQueryCursor cursor -> do
        _ <-
          resetSubscriptionCheckpointsTx
            (NonEmpty.singleton (SubscriptionName cursor))
            replayFrom
        pure ()
    pure metadata
```

Update the `startRebuild` Haddock (and the numbered checklist in the module header, step
2) to state: a model with a durable cursor has every member of that subscription reset to
the replay position through Kiroku's public reset; a cursorless model
(`readModelCursorAuthority` is `NoQueryCursor`) has no checkpoint to reset, so the
rebuild deliberately skips that step and performs only the fence, truncate, and dedup
clear — pair it with an empty projection-name list, the inline-only shape `finishRebuild`
already exempts from its empty-rebuild guard.

Then perform the scaffold audit — read-only; record the findings in this plan's
Surprises & Discoveries (or Decision Log if a decision emerges). Confirm in
`keiro-dsl/src/Keiro/Dsl/Scaffold.hs` that (a) `emitReadModelGenWithContract` emits
`cursorAuthority = NoQueryCursor` exactly when `ownerDerivedCursor` resolves no
subscription (owner delivery is inline), near lines 4099-4112 and 4732; (b) the legacy
lifecycle block emitting `startXxxRebuild` is generated for every non-catalog-managed
model, near lines 4754-4772, and pairs cursorless models with an empty projection-name
list; and (c) therefore the runtime fix makes the generated pairing correct as-is: the
generated `startXxxRebuild` becomes a working fence/truncate lifecycle for an inline
model, and no emitter change or corpus regeneration is needed (published generated bytes
are frozen; changing them is explicitly out of scope, per the byte-freeze policy noted in
plan 244). Verify no checked-in generated conformance module currently pairs
`NoQueryCursor` with `Rebuild.startRebuild`:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
for f in $(grep -rln "Rebuild.startRebuild" keiro-dsl/test/); do grep -l "NoQueryCursor" "$f"; done
```

Expected output: only `keiro-dsl/test/Main.hs` (which mentions both tokens for unrelated
assertions); no generated `ReadModel.hs` module appears. If one does, read it and confirm
the fixed runtime semantics are correct for it, and note it here.

Acceptance for Milestone 3: the third "cursorless" test passes; the existing rebuild
runbook example ("runs the documented rebuild runbook..." near line 3700) still passes,
proving cursor-bearing rebuilds still reset the checkpoint to the replay position; the
audit findings are recorded in this plan.

### Milestone 4 — Documentation, changelog, full verification

Scope: user docs, changelog, full gates, plan/MasterPlan bookkeeping.

Documentation. In `docs/user/read-models-and-projections.md`: in the "0.12 compatibility
and 0.13 removal" section, add a sentence stating that waiting overrides
(`Strong`, `PositionWait` with a target) and `waitFor` on a cursorless model fail fast
with `ReadModelMissingCursor`, exactly like `runQueryWithFreshness` — the compatibility
table's "exact behavior retained" column applies to models with real cursors, and no
0.11 source can construct a cursorless model. In the "Legacy Rebuild Lifecycle" section,
amend step 2 to say the checkpoint-reset step applies to each named subscription of a
cursor-bearing model and is skipped for a cursorless model (nothing to reset; pair with
an empty projection-name list). In the "Errors" section, widen the
`ReadModelMissingCursor` line from "a truthful wait" to any wait — truthful freshness,
deprecated waiting override, or `waitFor` — requested on a cursorless model. In
`docs/user/api-reference.md`, the `Keiro.ReadModel` section's closing paragraph (after
the deprecated list, near line 412) gets the same one-sentence fail-fast note. Keep both
documents' existing voice and table formats.

Changelog. Add to `keiro/CHANGELOG.md` under `## Unreleased` / `### Fixed`:

```text
- Cursorless read models (built via `immediateReadModel` with `NoQueryCursor`) now fail
  fast with the typed `ReadModelMissingCursor` on every public wait path: the exported
  `waitFor` and the deprecated `runQueryWith` waiting overrides no longer poll the
  internal cursor sentinel for the full timeout or record a spurious
  `keiro.projection.wait.timeouts` increment. Behavior for models with durable cursors,
  including all directly constructed 0.11 records, is unchanged.
- `Keiro.ReadModel.Rebuild.startRebuild` now recognizes a cursorless model through
  `readModelCursorAuthority` and skips the subscription-checkpoint reset because there is
  no cursor to reset. It no longer passes the private NUL-prefixed compatibility sentinel
  into Kiroku, while preserving the documented fence, truncate, and dedup clear used by
  generated inline Language-5 rebuild helpers.
```

ADRs: per the Decision Log, no ADR is amended or created; re-confirm that judgment
against the final diff before closing (if the `startRebuild` ruling turned into a durable
contract change during implementation, amend `docs/adr/0033-...` or create a new ADR in
the same change and update the Decision Log).

Verification: run the full suite and the repository gate (commands in Concrete Steps).
Update the MasterPlan 40 registry row for this plan to Complete, write Outcomes &
Retrospective, and finish the living sections.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`.

Milestone 1 (red):

```bash
cabal build keiro-test
cabal test keiro-test --test-option=--match --test-option="cursorless"
```

Observed before the fix: 3 examples, 2 failures. The `waitFor` example fails after roughly five
seconds expecting `ReadModelMissingCursor` but getting
`ReadModelWaitTimeout "counter-read-model" (GlobalPosition 5) (GlobalPosition 0)`; the
override example fails the same way against the visible head captured from the appended
event, and its metric lookup reports `Just (IntNumber 2)` instead of `Nothing`. The
cursorless rebuild example passes on the current Hasql/PostgreSQL parameter path.

Milestones 2 and 3 (green), after the edits to `keiro/src/Keiro/ReadModel.hs` and
`keiro/src/Keiro/ReadModel/Rebuild.hs`:

```bash
cabal build all
cabal test keiro-test --test-option=--match --test-option="cursorless"
cabal test keiro-test --test-option=--match --test-option="Keiro.ReadModel"
```

Expected: the three cursorless examples pass with the whole match finishing in a few
seconds (no five-second burns); the full `Keiro.ReadModel` match passes with zero
failures.

Milestone 4 (full gates):

```bash
cabal test keiro-test
just verify
```

Expected: zero failed examples in `keiro-test`; `just verify` completes its full sequence
(jitsurei demo, all package test suites, ADR/research/capability validation, policy and
corpus gates) successfully. Record actual counts in this plan.

### Commit and trailer convention

Use Conventional Commits (`test(read-model): ...`, `fix(read-model): ...`,
`fix(rebuild): ...`, `docs(read-model): ...`) on the current branch, and include on every
commit for this plan the trailers:

```text
MasterPlan: docs/masterplans/40-fix-the-remaining-runtime-and-dsl-defects-from-the-fix-verification-review.md
ExecPlan: docs/plans/252-fail-fast-on-cursorless-strong-waits-in-the-legacy-read-model-api.md
Intention: intention_01kzw6dkcserms9yr61sqdntep
```


## Validation and Acceptance

Acceptance is behavioral, verified through the commands above:

1. `waitFor` with any options and target on a cursorless model returns
   `Left (ReadModelMissingCursor <name> (WaitForPosition <options with the concrete
   target>))` in well under the configured timeout (asserted `< 2` seconds against the
   five-second default), and the `keiro.projection.wait.timeouts` counter exports no
   point for the call. Before the fix the same call takes the full timeout, returns
   `ReadModelWaitTimeout <name> <target> (GlobalPosition 0)`, and increments the counter.
2. `runQueryWith Strong` on a cursorless model with a non-empty visible log returns
   `Right (Left (ReadModelMissingCursor <name> (WaitForHead <scope>)))` — the identical
   value `runQueryWithFreshness (WaitForHead <scope>)` returns on the same model — in
   well under the timeout, with no timeout-counter point; `runQueryWith (PositionWait
   ...)` with a target behaves the same with a `WaitForPosition` payload.
3. Every pre-existing `Keiro.ReadModel` example passes unchanged, in particular the
   legacy/truthful equivalence examples and the "counts a position-wait timeout in the
   timeout counter" example (a genuine timeout on a cursor-bearing model still increments
   the counter exactly once), and `keiro/test/Compatibility/ReadModel011.hs` still
   compiles. This is the plan-244 compatibility window holding.
4. `startRebuild` on a cursorless model returns `Right` metadata with status
   `Rebuilding`, truncates the data table, leaves every `subscriptions` row untouched,
   and `finishRebuild` with an empty projection list promotes it to `Live`; the existing
   cursored runbook example still observes its checkpoint reset to the replay position.
5. `cabal test keiro-test` reports zero failures and `just verify` passes end to end.


## Idempotence and Recovery

Every step is repeatable. Tests run against per-example databases cloned from the
suite-level template fixture, so re-running a failed suite is always safe. The source
edits are small and localized to two functions plus one new private helper; if a
Milestone 2 edit goes wrong, `git checkout -- keiro/src/Keiro/ReadModel.hs` restores the
baseline and the red tests reproduce the defect again. The Milestone 3 edit is guarded by
the existing cursored rebuild tests; if they fail, the branch on
`readModelCursorAuthority` is wrong (most likely inverted or applied to the wrong field)
— revert and re-apply. No migration, data change, or destructive operation is involved
anywhere; the throwaway PostgreSQL check quoted in Context was planning-time evidence
only and is not part of implementation.


## Interfaces and Dependencies

No public signature changes and no new exports. At the end of Milestone 2,
`keiro/src/Keiro/ReadModel.hs` still exports exactly the surface it does today;
internally, `waitFor :: Maybe KeiroMetrics -> PositionWaitOptions -> ReadModel q r ->
GlobalPosition -> Eff es (Either ReadModelError ())` is implemented via `withCursor`, a
private `legacyOverrideFreshness :: ConsistencyMode -> ReadModel q r -> QueryFreshness`
exists and is the shared translation under both `readModelDefaultFreshness` and
`runQueryWith`, and `waitIfNeeded` no longer exists. At the end of Milestone 3,
`startRebuild :: ReadModel q r -> [Text] -> GlobalPosition -> Eff es ReadModelMetadata`
in `keiro/src/Keiro/ReadModel/Rebuild.hs` keeps its signature and branches on
`readModelCursorAuthority`. The only dependency contract relied on is Kiroku's
`resetSubscriptionCheckpointsTx` (package `kiroku-store`,
`mori://shinzui/kiroku/packages/kiroku-store`): it updates only existing rows for the
requested names and never creates rows — the fix stops passing it a name that PostgreSQL
does not identify any durable cursor. Test-side, the new examples use only what
`keiro/test/Main.hs` already imports: the OpenTelemetry in-memory exporter harness,
`Keiro.ReadModel(.Rebuild)`, and the counter fixtures; the new
`counterCursorlessRebuildReadModel` fixture derives from the existing
`counterReadModelBlueprint`. No new package dependencies.

Revision note (2026-08-13): implementation evidence corrected the planned rebuild
failure mode. The actual Hasql/PostgreSQL path accepted the cursor sentinel before the
fix, so the plan, changelog guidance, and parent MasterPlan now describe the verified
capability-boundary leak instead of claiming an unreproduced SQLSTATE 22021 abort. The
typed `NoQueryCursor` skip and its behavioral acceptance remain unchanged.
