---
id: 18
slug: add-guide-backed-jitsurei-examples
title: "Add guide-backed jitsurei examples"
kind: exec-plan
created_at: 2026-05-17T15:42:51Z
intention: "intention_01krv9hx6vetp9gbm13asrvnnp"
---

# Add guide-backed jitsurei examples

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Keiro has concise user documentation in `docs/user/`, but a new adopter still has to infer a complete application shape from prose and from the large integration test in `test/Main.hs`. After this change, the repository will contain a sibling `jitsurei` Cabal package whose name means "real example" and whose source files are the runnable code backing the new long-form guides in `docs/guides/`. A reader will be able to open a guide, follow a real order-fulfillment example, and then run commands such as `cabal test jitsurei-test` to prove that the sample code referenced by the guide actually compiles and behaves as described.

The user-visible outcome is a documentation set that teaches Keiro through a realistic business workflow rather than disconnected snippets. The example should show a command-side aggregate, event codec evolution, inline and async read-model projection shapes, snapshots, a process manager, durable timers, and operational setup. The guides should link to exact modules in `jitsurei/src/` and `jitsurei/test/` so sample code is not duplicated into stale Markdown blocks.


## Progress

- [x] Create `jitsurei/jitsurei.cabal`, add `jitsurei` to `cabal.project`, and define the package's library, executable, and test-suite. Completed 2026-05-17T15:54:59Z.
- [x] Move the existing small counter/order patterns from `test/Main.hs` into guide-quality example modules under `jitsurei/src/Jitsurei/`, adapted into one cohesive order-fulfillment domain. Completed 2026-05-17T15:54:59Z with `Jitsurei.Domain`, `Jitsurei.OrderStream`, `Jitsurei.ReadModels`, `Jitsurei.FulfillmentProcess`, `Jitsurei.Timers`, `Jitsurei.Snapshots`, and `Jitsurei.Database`.
- [x] Add focused tests under `jitsurei/test/` that exercise the code paths the guides promise: command execution, codec evolution, inline read-model projection, snapshot hydration, process-manager dispatch, and timer firing. Completed 2026-05-17T15:54:59Z; `cabal test jitsurei-test` passed with 7 examples and 0 failures.
- [x] Add `docs/guides/README.md` plus long-form guide pages for the sample application's domain model, command cycle, event evolution, read models, process managers, timers, snapshots, migrations, and operations. Completed 2026-05-17T15:59:25Z.
- [x] Cross-link `docs/user/README.md` and related `docs/user/*.md` pages to the new `docs/guides/` entry point without replacing the existing API-oriented docs. Completed 2026-05-17T15:59:25Z.
- [x] Update `Justfile`, `README.md`, or both so local verification includes the new package and guide-backed examples. Completed 2026-05-17T15:59:25Z; `haskell-test` now runs both `keiro-test` and `jitsurei-test`, and `README.md` points to `docs/guides/README.md`.
- [x] Run Haskell and documentation validation commands and record the observed outputs in this plan. Completed 2026-05-17T15:59:25Z.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)

- Observation: Keiro examples that need v7-shaped identifiers should not generate them through the `uuid` package.
  Evidence: The user clarified during implementation that the `uuid` package does not support UUIDv7 yet. `jitsurei` now depends on local `mmzk-typeid` and obtains timer/event UUID fixtures through `Data.TypeID.V7.parseText` and `getUUID`.
  Date: 2026-05-17


## Decision Log

Record every decision made while working on the plan.

- Decision: Build one cohesive `jitsurei` sibling package instead of only adding more Markdown examples.
  Rationale: The current docs already say `test/Main.hs` is the best complete executable source. A dedicated package makes guide examples importable, testable, and safe to reference from docs without turning the main test suite into user-facing tutorial material.
  Date: 2026-05-17

- Decision: Keep `docs/user/` as the concise reference layer and add `docs/guides/` as the narrative example layer.
  Rationale: The existing user docs cover the public surface module-by-module. The user asked for more extensive guides, and placing them in `docs/guides/` avoids mixing tutorial prose with the current quick-reference pages.
  Date: 2026-05-17

- Decision: Use an order-fulfillment workflow as the real-world example domain.
  Rationale: Orders naturally demonstrate stream naming, commands, multi-event decisions, read-side projections, fulfillment process managers, payment/shipping timers, and schema evolution without inventing artificial framework-only scenarios.
  Date: 2026-05-17

- Decision: Add local `mmzk-typeid` to `cabal.project` and use `Data.TypeID.V7` for v7-compatible identifier fixtures.
  Rationale: Timer and process-manager examples ultimately pass UUID values to Keiro/Kiroku types, but the examples should not imply that the `uuid` package can generate UUIDv7 values. TypeID supplies a local API that supports v7 TypeIDs and exposes the underlying UUID for the existing Keiro interfaces.
  Date: 2026-05-17

- Decision: Copy `jitsurei/` into `site-dist/` during website builds.
  Rationale: The guide pages intentionally link to source files as the canonical code. The static link checker only sees generated `site-dist/` content, so copying the package source lets guide-to-source links be checked locally.
  Date: 2026-05-17

- Decision: Refactor `jitsurei` to use Keiki's builder DSL and record payloads for commands and events.
  Rationale: The original implementation used lower-level `Edge` constructors because that matched Keiro's integration tests, but `jitsurei` is guide-facing and should model realistic authoring style. Record payloads make examples extensible and readable, and the builder DSL is the Keiki authoring surface that application code should learn first.
  Date: 2026-05-17

- Decision: Add a Mermaid state diagram to the command-side guide.
  Rationale: The order lifecycle is the central concept in the guide-backed example. A state diagram makes the accepted commands, emitted events, and terminal states visible before readers inspect code.
  Date: 2026-05-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)

- Outcome: The repository now contains a `jitsurei` sibling package with a library, demo executable, and `jitsurei-test` suite. The code backs the new guide set in `docs/guides/` and covers the requested real-world examples: command execution, event evolution, read models, process-manager idempotency, timers, and snapshots.
  Gaps: The example remains intentionally library-shaped rather than a web service. It demonstrates the Keiro runtime pieces without adding an HTTP API, deployment manifests, or async Shibuya worker wiring.
  Date: 2026-05-17

- Outcome: The guide-facing command side was revised to use Keiki's builder DSL and record payload constructors such as `PlaceOrder PlaceOrderData` and `OrderPlaced OrderPlacedData`.
  Gaps: The DSL's Template Haskell helper emits some extra projection helpers that are not needed by this small example. They are harmless, but future polish can decide whether to export them as teaching aids or suppress the unused-binding warnings locally.
  Date: 2026-05-17


## Context and Orientation

This repository is the `shinzui/keiro` Haskell framework. The local `mori.dhall` identifies it as an event sourcing and workflow framework with declared dependencies on `shinzui/kiroku`, `shinzui/keiki`, `shinzui/shibuya`, `hasql/hasql`, and `effectful/effectful`. The root `cabal.project` currently includes the main `keiro` package, `keiro-migrations`, and local sibling dependency paths for `keiki`, `keiki-codec-json`, `kiroku-store`, and `kiroku-store-migrations`.

An event-sourced application stores facts as an append-only event stream and recreates current state by replaying those facts. In this repository, `src/Keiro/Stream.hs` provides typed stream names, `src/Keiro/Codec.hs` encodes and decodes JSON events with schema-version metadata, `src/Keiro/EventStream.hs` defines the contract that joins a Keiki state machine to a Keiro event codec, and `src/Keiro/Command.hs` implements `runCommand`, the load-replay-decide-append cycle. A "read model" is a table optimized for queries rather than event replay; `src/Keiro/ReadModel.hs` and `src/Keiro/Projection.hs` provide helpers for inline and asynchronous projection shapes. A "process manager" is a stateful coordinator that reacts to one stream's event and emits commands to another stream; `src/Keiro/ProcessManager.hs` provides deterministic command ids for replay-safe dispatch. A "durable timer" is a database-backed scheduled action; `src/Keiro/Timer.hs` and `src/Keiro/Timer/Schema.hs` provide scheduling and claiming helpers.

The current user docs live under `docs/user/`. The entry point `docs/user/README.md` states that the test suite in `test/Main.hs` is the best complete executable example until a dedicated sample application exists. `docs/user/getting-started.md` shows small snippets for stream, codec, event stream, command execution, and schema initialization. `docs/user/command-cycle.md`, `docs/user/codecs-and-event-evolution.md`, `docs/user/read-models-and-projections.md`, `docs/user/process-managers-and-timers.md`, `docs/user/snapshots.md`, `docs/user/migrations.md`, and `docs/user/operations.md` describe the public concepts but do not point to a cohesive application package.

The existing `test/Main.hs` file contains most of the working examples that should inform `jitsurei`: `counterEventStream`, `multiCounterEventStream`, `snapshotCounterEventStream`, `counterCodec`, `counterReadModel`, `counterInlineProjection`, `counterAsyncProjection`, `counterProcessManager`, `workflowProcessManager`, timer requests, and an `EphemeralPg`-backed `withTestStore`. These examples prove the current APIs but are intentionally compact and test-oriented. The new package should reuse their lessons, not literally expose the test module as documentation.

The `keiro-migrations/` sibling package demonstrates the existing sibling-package style. It has its own `keiro-migrations/keiro-migrations.cabal`, source under `keiro-migrations/src/`, an executable under `keiro-migrations/app/`, and tests under `keiro-migrations/test/`. The `jitsurei/` package should follow this shape.


## Plan of Work

Milestone 1 creates the sample package skeleton. Add `jitsurei` to the `packages:` list in `cabal.project`. Create `jitsurei/jitsurei.cabal` with a library named `jitsurei`, an executable named `jitsurei-demo`, and a test-suite named `jitsurei-test`. Use the same `cabal-version`, `GHC2024`, warning profile, and package style as `keiro.cabal`; include dependencies already used by Keiro's tests such as `aeson`, `contravariant-extras`, `effectful`, `effectful-core`, `ephemeral-pg`, `hasql`, `hasql-transaction`, `hspec`, `keiki`, `keiki-codec-json`, `keiro`, `kiroku-store`, `text`, `time`, `uuid`, and `vector`. Add placeholder modules `jitsurei/src/Jitsurei.hs`, `jitsurei/app/Main.hs`, and `jitsurei/test/Main.hs` that compile. This milestone is accepted when `cabal build jitsurei:lib:jitsurei jitsurei:exe:jitsurei-demo` and `cabal test jitsurei-test` run without relying on any guide prose.

Milestone 2 implements the domain example. Create modules under `jitsurei/src/Jitsurei/` for a small order-fulfillment application. `Jitsurei.Domain` defines `OrderId`, `Sku`, `Quantity`, commands such as `PlaceOrder`, `ApprovePayment`, `MarkPacked`, `ShipOrder`, and `CancelOrder`, events such as `OrderPlaced`, `PaymentApproved`, `OrderPacked`, `OrderShipped`, and `OrderCancelled`, and the current order state. `Jitsurei.OrderStream` defines the Keiki `SymTransducer`, the `Codec OrderEvent`, and the `EventStream` value using Keiro's public API. Keep the logic realistic: an order can be placed, paid, packed, shipped, or cancelled, and invalid commands are rejected by the transducer. This milestone is accepted when tests prove command execution appends the expected ordered events and rejects an impossible transition such as shipping an unpaid order.

Milestone 3 adds guide-backed persistence examples. Create `Jitsurei.Database` with schema initialization helpers for the example's own read-model tables and functions that call Keiro's `initializeSnapshotSchema`, `initializeReadModelSchema`, and `initializeTimerSchema` for local/test setup. Create `Jitsurei.ReadModels` with an inline projection that maintains an `order_summary` table and a `ReadModel` query returning status, quantity, and last event position. Add tests using `EphemeralPg` and `Kiroku.Store.runStoreIO` to prove a command can append an event and update the read model inside the same transaction through `runCommandWithProjections` or `runCommandWithSqlEvents`. This milestone is accepted when `cabal test jitsurei-test --test-options '--match "/read model/"'` or an equivalent Hspec match passes and shows the queried summary changes after commands.

Milestone 4 adds process-manager, timer, snapshot, and codec-evolution examples. Create `Jitsurei.FulfillmentProcess` to react to `PaymentApproved` and emit a packing command with deterministic command ids through `runProcessManagerOnce`. Create `Jitsurei.Timers` to schedule a payment-timeout timer when an order is placed, then mark it fired through `runTimerWorker`. Create `Jitsurei.Snapshots` or extend `Jitsurei.OrderStream` with a `StateCodec` and `Every 2` or similar snapshot policy. Add a version-1-to-version-2 event upcaster in `Jitsurei.OrderStream` that mirrors the guide's story of evolving an event payload. Tests must prove duplicate process-manager dispatch is idempotent, a due timer can be claimed and marked fired, snapshot rows are written, and old JSON payloads decode into current events. This milestone is accepted when all `jitsurei-test` specs pass against an ephemeral PostgreSQL database.

Milestone 5 writes the guide set and links it into existing docs. Create `docs/guides/README.md` as the table of contents and add the following pages: `docs/guides/order-fulfillment-overview.md`, `docs/guides/build-the-command-side.md`, `docs/guides/evolve-events-safely.md`, `docs/guides/project-read-models.md`, `docs/guides/process-managers-and-timers.md`, `docs/guides/snapshots-and-hydration.md`, and `docs/guides/run-and-operate-jitsurei.md`. Each guide should explain concepts in prose, show short excerpts only where helpful, and link to the full source path in `jitsurei/src/` or `jitsurei/test/`. Update `docs/user/README.md` to add a "Long-form guides" section pointing at `../guides/README.md`; add one-sentence "See the guide-backed example" links in relevant `docs/user/*.md` files. This milestone is accepted when a reader can start at `docs/guides/README.md`, navigate to each guide, and find a working source file for every substantial code claim.

Milestone 6 updates verification and records evidence. Update `Justfile` so Haskell verification covers the new package explicitly if `cabal build all` and `cabal test all` are not already sufficient. Update `README.md` development instructions to mention `cabal test jitsurei-test` as the guide-backed example validation command. Run `cabal build all`, `cabal test keiro-test`, `cabal test jitsurei-test`, and the existing website/documentation verification path if available. This milestone is accepted when the commands pass, or when any failure is documented in this plan with a clear reason and a concrete follow-up.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
```

Before editing dependency-facing code, refresh local dependency context with Mori and inspect source/docs rather than guessing APIs:

```bash
mori show --full
mori registry show shinzui/keiki --full
mori registry show shinzui/kiroku --full
mori registry show effectful/effectful --full
```

Expected output includes the current project identity as `shinzui/keiro`, `keiki` at `/Users/shinzui/Keikaku/bokuno/keiki`, `kiroku` at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`, and `effectful` at `/Users/shinzui/Keikaku/hub/haskell/effectful-project`. Do not search or read `/nix/store`; it is not source context for this work.

Create directories for the sample package and guides:

```bash
mkdir -p jitsurei/src/Jitsurei jitsurei/app jitsurei/test docs/guides
```

Edit `cabal.project` so the package list begins like this:

```cabal
packages:
  .
  keiro-migrations
  jitsurei
  /Users/shinzui/Keikaku/bokuno/keiki
```

Create `jitsurei/jitsurei.cabal` modeled on `keiro.cabal` and `keiro-migrations/keiro-migrations.cabal`. The library should expose at least:

```text
Jitsurei
Jitsurei.Database
Jitsurei.Domain
Jitsurei.FulfillmentProcess
Jitsurei.OrderStream
Jitsurei.ReadModels
Jitsurei.Snapshots
Jitsurei.Timers
```

Keep the executable small. `jitsurei/app/Main.hs` should import `Jitsurei` and print or run a tiny deterministic demonstration that does not require a long-running service. The tests in `jitsurei/test/Main.hs` should be the primary executable proof.

Implement the domain and tests incrementally. After each milestone, run the narrowest useful command first:

```bash
cabal build jitsurei:lib:jitsurei
cabal test jitsurei-test
```

After the package is wired into the workspace, run the broader build:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
```

When adding guide pages, keep code snippets short and make the source file link the canonical copy. For example, a guide may show the shape of a command:

```haskell
data OrderCommand
  = PlaceOrder OrderId Sku Quantity
  | ApprovePayment OrderId
  | MarkPacked OrderId
  | ShipOrder OrderId
  | CancelOrder OrderId Text
```

Then it should immediately point to the full implementation at `jitsurei/src/Jitsurei/Domain.hs` and the behavior tests at `jitsurei/test/Main.hs`.

Run the documentation site verification after guide links are in place:

```bash
just website-verify
```

If `pnpm install --frozen-lockfile` or another website step needs network access and fails for environmental reasons, record the failure text in this plan and still run the local link checker if `site-dist/` can be built.


## Validation and Acceptance

The implementation is accepted only when the sample package and the guides verify each other. `cabal test jitsurei-test` must execute at least one test for each guide-backed behavior: placing an order appends `OrderPlaced`; approving payment and packing/shipping follows valid state transitions; invalid commands are rejected as domain outcomes; a version-1 stored JSON event is upcast and decoded as the current event type; the inline read model query returns the status written by the projection; a process manager emits a deterministic packing command and treats duplicate source events idempotently; a timer can be scheduled, claimed, and marked fired; and snapshot policy writes a row that later command hydration can use.

The expected successful Haskell transcript should be close to:

```text
$ cabal test jitsurei-test
Running 1 test suites...
Test suite jitsurei-test: RUNNING...
...
Finished in ... seconds
... examples, 0 failures
Test suite jitsurei-test: PASS
```

Observed on 2026-05-17T15:54:59Z:

```text
$ cabal test jitsurei-test
Jitsurei codec evolution
  upcasts a v1 OrderPlaced payload into the current event shape [✔]
Jitsurei command cycle
  places and pays for an order in stream order [✔]
  rejects shipping an unpaid order as a domain outcome [✔]
Jitsurei read model
  updates and queries the inline order summary in the append transaction [✔]
Jitsurei snapshots
  writes a snapshot after the configured threshold [✔]
Jitsurei process manager
  dispatches a packing command once for a payment event [✔]
Jitsurei timers
  claims a due timer and marks it fired [✔]

7 examples, 0 failures
Test suite jitsurei-test: PASS
```

The repository-wide validation must include:

```bash
cabal build all
cabal test keiro-test
cabal test jitsurei-test
just website-verify
```

Observed on 2026-05-17T15:59:25Z:

```text
$ cabal build all
Build completed successfully.

$ cabal test keiro-test
33 examples, 0 failures
Test suite keiro-test: PASS

$ cabal test jitsurei-test
7 examples, 0 failures
Test suite jitsurei-test: PASS

$ just website-verify
Built 34 site pages plus the source-doc index into site-dist/
No broken file links across 36 HTML pages
```

Observed after the DSL and record-payload revision on 2026-05-17T17:58:56Z:

```text
$ cabal test jitsurei-test
7 examples, 0 failures
Test suite jitsurei-test: PASS

$ cabal build all
Build completed successfully.

$ just website-verify
Built 34 site pages plus the source-doc index into site-dist/
No broken file links across 36 HTML pages
```

The guide acceptance criteria are human-readable and source-backed. `docs/guides/README.md` must list all guide pages. Each guide must state the concrete outcome it teaches and link to one or more exact source files under `jitsurei/`. The existing `docs/user/README.md` must link to `docs/guides/README.md`, and at least the command cycle, codecs, read models, process managers/timers, snapshots, migrations, and operations user-doc pages must point to their corresponding guide page.

Do not consider the work complete if the guides contain large copied code blocks that can drift from `jitsurei`. Short excerpts are acceptable, but the executable source files and tests are the source of truth.


## Idempotence and Recovery

Adding `jitsurei` and `docs/guides/` is additive. Re-running `cabal build all`, `cabal test jitsurei-test`, and `just website-verify` is safe. The tests should use `EphemeralPg` like `test/Main.hs` so they create isolated PostgreSQL instances and do not mutate a developer's persistent database.

If the first package skeleton does not compile, keep the package listed in `cabal.project` and fix one module at a time rather than removing it from the workspace. If a guide page points to a module that later gets renamed, update the guide link in the same commit as the source move. If website verification fails because the site generator does not yet include `docs/guides/`, update `site/build.mjs` or the relevant site input list so the new docs are rendered and link-checked. If the failure is an environment issue such as a missing package download, record the exact command and error in Progress or Surprises & Discoveries.

The work should not require destructive database or Git operations. Do not delete or rewrite existing `docs/user/` pages; only add cross-links and small references to the new guides. Do not traverse `/nix/store` while looking for dependency code.


## Interfaces and Dependencies

The `jitsurei` package depends on Keiro's public modules rather than internal helpers. The core imports should be `Keiro`, `Keiro.Command`, `Keiro.Codec`, `Keiro.EventStream`, `Keiro.Projection`, `Keiro.ReadModel`, `Keiro.Snapshot`, `Keiro.Stream`, `Keiro.ProcessManager`, and `Keiro.Timer` as needed. It should import `Keiki.Core` for `SymTransducer`, `RegFile`, and the symbolic transition constructors in the same style as `test/Main.hs`. It should import `Kiroku.Store` and `Kiroku.Store.Types` for test execution and event-store assertions, and `Hasql.Transaction`, `Hasql.Statement`, `Hasql.Encoders`, and `Hasql.Decoders` for read-model SQL.

At the end of the work, these guide-facing modules and interfaces should exist:

```haskell
module Jitsurei.Domain where

newtype OrderId = OrderId Text
newtype Sku = Sku Text
newtype Quantity = Quantity Int

data OrderCommand
data OrderEvent
data OrderState
```

```haskell
module Jitsurei.OrderStream where

orderCodec :: Codec OrderEvent
orderEventStream :: EventStream phi rs OrderState OrderCommand OrderEvent
orderStream :: OrderId -> Stream (EventStream phi rs OrderState OrderCommand OrderEvent)
```

The exact `phi` and `rs` type parameters should match the Keiki transducer chosen during implementation. It is acceptable to introduce a type alias such as `type OrderEventStream = EventStream ...` to make guide links easier to read.

```haskell
module Jitsurei.ReadModels where

data OrderSummaryQuery
data OrderSummary
orderSummaryReadModel :: ReadModel OrderSummaryQuery (Maybe OrderSummary)
orderSummaryInlineProjection :: InlineProjection OrderEvent
```

```haskell
module Jitsurei.FulfillmentProcess where

fulfillmentProcessManager :: ProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo
runFulfillmentOnce :: ... -> Eff es ...
```

The concrete process-manager type may be verbose. Prefer a type alias with a plain name and keep exported functions easy for guide readers to follow.

```haskell
module Jitsurei.Timers where

paymentTimeoutRequest :: OrderId -> UTCTime -> TimerRequest
runPaymentTimeoutWorker :: ... -> Eff es (Maybe TimerRow)
```

```haskell
module Jitsurei.Database where

initializeJitsureiTables :: (Store :> es) => Eff es ()
initializeOrderSummaryTable :: Tx.Transaction ()
```

The test support can live in `jitsurei/test/Main.hs` or `jitsurei/test/Jitsurei/TestStore.hs`; it may reuse the `EphemeralPg` pattern from the root `test/Main.hs`. All examples should use the package APIs as a user would, not hidden test-only shortcuts, except for ordinary test setup and assertions.
