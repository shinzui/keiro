---
id: 83
slug: delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes
title: "Delegated-idempotence inbox intake: bypass the keiro_inbox table when the downstream state machine already dedupes"
kind: exec-plan
created_at: 2026-07-02T02:34:14Z
intention: "intention_01kwganm3be0q8z4g6rmcqdj05"
---

# Delegated-idempotence inbox intake: bypass the keiro_inbox table when the downstream state machine already dedupes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

keiro's idempotent inbox (`keiro/src/Keiro/Inbox.hs`) guarantees that a Kafka-delivered integration event runs its local handler at most once by inserting a row into the Postgres table `keiro_inbox`, keyed on `(source, dedupe_key)`, in the same transaction as the handler. That guarantee is exactly right when the handler's effects are arbitrary SQL. But many consumers do exactly one thing in their handler: dispatch a command into an event-sourced aggregate under a *deterministic event id*, or seed a durable workflow under a *deterministic workflow id*. Both of those targets are already idempotent state machines — the event store's unique constraint on event ids collapses a replayed command into a benign duplicate, and a workflow journal only ever appends a given step once. For those consumers, the `keiro_inbox` insert is a second uniqueness check on the same identity: it costs an extra row write, unique-index maintenance, WAL volume, table bloat, and a periodic garbage-collection pass, and it buys nothing the downstream state machine does not already provide.

After this plan, a consumer whose handler is fully guarded by a downstream state machine can opt into **delegated idempotence**: a new entry point `runInboxDelegated` (plus a batch variant) computes the same dedupe key as today — key computation is pure, no I/O — but never touches `keiro_inbox`. Instead, the handler must *prove* it delegated the duplicate check by returning a witness value, `DelegatedOutcome`, that it can only construct by folding the downstream duplicate signal (the store's `DuplicateEvent` rejection, a process-manager `PMCommandDuplicate`, or an already-seeded workflow instance). The wrapper maps that witness back onto the existing `InboxResult` classification, so metrics, ack dispositions, and the keiro-dsl disposition table all keep working unchanged.

Observable outcome: an hspec test delivers the same integration event twice through a delegated intake whose handler appends to an aggregate under a deterministic event id; the first delivery classifies as `InboxProcessed`, the second as `InboxDuplicate`, the aggregate stream contains the event exactly once, and `listInbox` proves the `keiro_inbox` table has zero rows for that source. A `.keiro` intake spec can declare `idempotence delegated`, `keiro-dsl scaffold` emits the mode alongside the dedupe policy, and `keiro-dsl diff` exits non-zero when a spec changes the idempotence mode or the dedupe identity scheme, because those changes silently alter delivery semantics.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `DelegatedOutcome` and `InboxIdempotence` types added to `keiro/src/Keiro/Inbox/Types.hs`
- [ ] M1: `runInboxDelegated`, `runInboxDelegatedWithRetries`, `runInboxDelegatedBatch` added to `keiro/src/Keiro/Inbox.hs` with metrics classification and delegation-contract haddocks
- [ ] M1: `just haskell-build` green
- [ ] M2: `keiro/src/Keiro/Inbox/Delegated.hs` created with `delegatedEventId`, `delegatedFromCommand`, `delegatedFromPMCommand`, `delegatedWorkflowStart`; exported from `keiro.cabal` and re-exported where appropriate
- [ ] M3: hspec coverage in `keiro/test/Main.hs` — aggregate twice-delivery, workflow twice-delivery, batch in-batch duplicate, retries/poison metrics, zero-inbox-rows assertions; `cabal test keiro-test` green
- [ ] M4: DSL — `inkIdempotence` field in Grammar, `idempotence` clause in Parser, PrettyPrint round-trip, Skeleton default, Scaffold emits `inboxIdempotence`; `intakeDiff` wired into `diffSpecs` with new `DiagnosticCode`s; fixtures + `cabal test keiro-dsl-test` green
- [ ] M5: delegated conformance fixture (Generated module + hand-filled Integration) compiling in `keiro-dsl-conformance-intake-full`; conformance suites green
- [ ] M6: `inbox.delegated-single` and `inbox.delegated-batch-100` benches added; before/after numbers recorded in Outcomes & Retrospective; `keiro/bench/baseline-inbox.csv` regenerated
- [ ] M6: docs updated (`docs/user/integration-events.md`, `docs/guides/integration-events-with-kafka.md`, `docs/corpus/keiro-dsl-corpus.md`)
- [ ] Final: `just haskell-verify` green; Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: This plan is standalone, not a third child of `docs/masterplans/11-keiro-inbox-and-outbox-kafka-throughput-overhaul.md`.
  Rationale: Master plan 11 is complete (both child plans landed 2026-07-02) and its scope was hot-path cost reduction *within* the table-backed design. Delegated idempotence is a new API mode with DSL surface, not a tuning of the existing one. The master plan is referenced from Context instead.
  Date: 2026-07-02

- Decision: Delegated mode is a separate entry point (`runInboxDelegated`) with a different handler type, not a mode flag on `runInboxTransaction`.
  Rationale: The table-backed handler runs inside the inbox's own `Tx.Transaction` and cannot observe duplicates (the wrapper branches on the row). The delegated handler must run in `Eff es` (aggregate and workflow runners open their own store transactions) and must *report* duplicate detection. Different types, different contracts — overloading one function with both would force partiality.
  Date: 2026-07-02

- Decision: The duplicate report is a required witness type (`DelegatedOutcome a = DelegatedFresh !a | DelegatedDuplicate`), not documentation.
  Rationale: A consumer physically cannot compile a delegated handler without deciding where `DelegatedDuplicate` comes from. That converts the correctness contract ("your state machine must actually dedupe") from prose into a type obligation, and it keeps duplicate metrics accurate without the table.
  Date: 2026-07-02

- Decision: The delegated wrapper takes only `IOE :> es` (no `Store`); it performs no database work itself.
  Rationale: Key computation is pure; metrics recording needs IO. Requiring `Store` would be a lie in the signature and would block non-Postgres handlers (the whole point is that the *downstream* owns storage).
  Date: 2026-07-02

- Decision: Retry/poison accounting in delegated mode is driven by a caller-supplied delivery-attempt count, not by a Postgres ledger.
  Rationale: Without a failed row there is no durable attempt counter. The Kafka layer already has one — the consumer's redelivery loop (or a delivery-attempt header) — so `runInboxDelegatedWithRetries` accepts `attemptCeiling` and the current attempt number, returns `InboxHandlerFailed` below the ceiling and `InboxPreviouslyFailed` at it, and records the poisoned metric exactly as the table-backed path does. Dead-lettering the payload becomes the consumer's DLQ-topic responsibility; the plan documents this loss explicitly.
  Date: 2026-07-02

- Decision: Downstream adapters live in a new module `Keiro.Inbox.Delegated` rather than in `Keiro.Inbox`.
  Rationale: The adapters import `Keiro.Command`, `Keiro.ProcessManager`, and `Keiro.Workflow.*`. Nothing in `keiro/src` imports `Keiro.Inbox` (verified by grep), so the new module creates no cycle, and `Keiro.Inbox` keeps its narrow dependency footprint (Schema, Types, Telemetry, kiroku Store).
  Date: 2026-07-02

- Decision: In the DSL, a delegated intake still supplies the full seven-outcome disposition table.
  Rationale: The generated `inboxDisposition` is a total `case` over the live `InboxResult` type, whose constructors do not change. `inProgress` and `previouslyFailed` rows are unreachable at runtime in delegated mode but keeping them preserves totality, keeps the validator's completeness rule (`DispositionIncomplete`) uniform, and costs nothing. The scaffold emits a comment marking them unreachable.
  Date: 2026-07-02

- Decision: `keiro-dsl diff` gains intake coverage (`intakeDiff`) gating three things as Breaking: idempotence-mode changes, dedupe-policy changes, and dedupe-key-field changes.
  Rationale: `diffSpecs` currently walks only aggregates/events — intakes are not diffed at all. A mode or identity-scheme flip silently changes delivery semantics (which deliveries are collapsed, where failure records live), which is exactly the class of change diff-gating exists for. Policy/key changes are gated even in table mode: they change the dedupe identity of in-flight messages.
  Date: 2026-07-02

- Decision: No schema or migration changes.
  Rationale: Delegated mode writes nothing; the `keiro_inbox` table and its migrations are untouched. Everything in this plan is additive Haskell.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This is a Haskell monorepo built with cabal (`cabal.project` at the root) and orchestrated by a `Justfile`. The packages that matter here: `keiro/` (the runtime library: event-sourced commands, process managers, workflows, outbox, inbox), `keiro-core/` (the pure integration-event envelope contract), `keiro-dsl/` (a toolchain that parses `.keiro` service specifications, validates them, scaffolds Haskell modules, and diffs spec revisions for unsafe evolution), and `keiro-test-support/` (Postgres test fixtures; `withFreshStore` in `keiro-test-support/src/Keiro/Test/Postgres.hs` hands each hspec example a fresh store cloned from a suite-level template database, so `cabal test keiro-test` needs no externally managed Postgres).

Some vocabulary, all defined here so the plan is self-contained. An **integration event** (`Keiro.Integration.Event` in `keiro-core`) is a public message crossing bounded contexts over Kafka; its `messageId` is minted once at the producer's outbox enqueue and is stable across publish retries. The **inbox** is the consumer-side dedupe: `runInboxTransaction` (`keiro/src/Keiro/Inbox.hs`) computes a **dedupe key** from an `InboxDedupePolicy` (`keiro/src/Keiro/Inbox/Types.hs` — `PreferIntegrationMessageId`, `PreferSourceEventIdentity`, `KafkaDeliveryIdentity`, `CustomDedupeKey`; the computation `dedupeKeyFor` is pure), then in one Postgres transaction inserts a `completed` row into `keiro_inbox` via `tryInsertCompletedTx` (`keiro/src/Keiro/Inbox/Schema.hs`) and runs the caller's handler (`IntegrationEvent -> Tx.Transaction a`). A conflicting row classifies the delivery as `InboxDuplicate` / `InboxInProgress` / `InboxPreviouslyFailed` (the `InboxResult` type). `runInboxTransactionWithRetries` adds a Postgres-ledger attempt counter (`recordFailedAttemptTx`) and an attempt ceiling; `runInboxTransactionBatch` amortizes one commit across N messages with in-memory in-batch duplicate suppression (`planInboxBatch`, pure) and a per-message fallback on failure. Metrics are recorded through `recordInboxResult` against `Keiro.Telemetry.KeiroMetrics` counters (`recordInboxProcessed`, `recordInboxDuplicates`, `recordInboxFailed`, `recordInboxPoisoned`).

The **downstream state machines** this plan delegates to. First, aggregate command dispatch: `Keiro.Command.RunCommandOptions` carries `eventIds :: [EventId]`, caller-supplied ids assigned to emitted events; the kiroku event store enforces event-id uniqueness, so appending under a repeated id fails with `StoreFailed (DuplicateEvent …)` (a `CommandError`). `Keiro.ProcessManager.deterministicCommandId :: Text -> Text -> EventId -> Int -> EventId` shows the established recipe: a v5 UUID over a `:`-joined name string, and both `Keiro.ProcessManager` and `Keiro.Router` fold `DuplicateEvent` into a benign `PMCommandDuplicate` (see `keiro/src/Keiro/Router.hs`, "Dispatch is idempotent by construction"). `eventAlreadyIn` (`keiro/src/Keiro/ProcessManager.hs`) is the cheap pre-dispatch existence check. Second, durable workflows: `Keiro.Workflow.runWorkflow :: WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (WorkflowOutcome a)` journals each step append-if-absent, and `Keiro.Workflow.Instance.lookupInstance :: WorkflowName -> WorkflowId -> Eff es (Maybe WorkflowInstanceRow)` reads the one-row-per-instance summary table `keiro_workflows` — a `Just` row means this workflow identity was already seeded.

The **keiro-dsl intake surface**. An inbox consumer is specified as an `intake` block in a `.keiro` file (canonical fixture: `keiro-dsl/test/fixtures/intake.keiro`); the AST node is `IntakeNode` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` (fields include `inkDedupeKey :: Name`, `inkDedupePolicy :: Name`, `inkDisposition :: [DispositionRow]` where `InboxAction = IAckOk | IRetry Text | IDeadLetter (Maybe Text)`). The parser (`pIntake`, `keiro-dsl/src/Keiro/Dsl/Parser.hs`) reads `dedupe key <field> policy <PolicyName>` and a `disposition { <outcome> => <action> … }` table over exactly seven outcomes (`processed`, `duplicate`, `inProgress`, `previouslyFailed`, `decodeFailed`, `dedupeFailed`, `storeFailed`); the validator (`validateIntake`, `keiro-dsl/src/Keiro/Dsl/Validate.hs`) enforces completeness (`DispositionIncomplete`) and dangerous inversions, with `data Severity = Error | Warning` and a single `DiagnosticCode` registry. The scaffolder (`scaffoldIntake` / `emitIntakeGen`, `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`) emits one Generated module per intake exporting `inboxDedupePolicy :: InboxDedupePolicy` (the spec's policy name lowered verbatim onto the live runtime enum) and `inboxDisposition :: InboxResult a -> InboxAck`; the transaction runner and handler are hand-filled (see `keiro-dsl/test/conformance-intake-full/HospitalCapacity/IncidentInbox/Integration.hs`, which calls `runInboxTransaction Nothing inboxDedupePolicy …`). The differ (`keiro-dsl/src/Keiro/Dsl/Diff.hs`) classifies spec changes as `Additive` or `Breaking` via `Change`/`ChangeKind` (with `ckCode :: Maybe DiagnosticCode`), and the CLI (`keiro-dsl/app/Main.hs`, commands `parse`/`check`/`scaffold`/`diff`/`new`) exits non-zero on any `Breaking`. Important gap: `diffSpecs` currently walks only aggregates and events — intakes are not diffed at all. The `new` command's intake skeleton is `intakeSkeleton` in `keiro-dsl/src/Keiro/Dsl/Skeleton.hs`. The pretty-printer `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` must round-trip whatever the parser accepts.

Tests and benches. `keiro/test/Main.hs` is one large hspec file; the inbox specs live under `describe "Keiro.Inbox"` (around line 3299) wrapped in `around (withFreshStore fixture)`. The benchmark component `keiro-bench` (`keiro/bench/Main.hs`, tasty-bench) has an `InboxScenario` record driving scenarios named `inbox.single-full`, `inbox.single-nometrics`, `inbox.batch-100`, `inbox.single-slim`; the standing baseline is `keiro/bench/baseline-inbox.csv`, guarded by the manual `just bench-regression` target (`--time-mode wall --baseline … --fail-if-slower 25`). Recent history: plans 82 (`docs/plans/82-…md`) and master plan 11 already removed the double-write, the per-message gauge, and added batching/slim persistence — this plan is the next step, removing the table from the path entirely for consumers that can prove they don't need it.

Why the win is real but bounded, stated up front so nobody oversells it: the dedupe insert rides the same transaction as the handler, so delegated mode does not remove a network round trip on the happy path. It removes the `keiro_inbox` row write (25 columns), the unique-index maintenance, the WAL those generate, the table's growth, and the retention GC scan — and in duplicate storms it moves detection to an index the store maintains anyway. The bench milestone quantifies this honestly.


## Plan of Work

The work proceeds in six milestones. M1–M3 land the runtime feature end to end (types, entry points, adapters, behavior tests) and are independently shippable. M4–M5 teach the DSL to declare and gate the mode and prove the generated surface type-checks against the live runtime. M6 measures and documents.


### Milestone 1 — Runtime types and delegated entry points

Scope: the witness type, the mode enum, and three new functions in `Keiro.Inbox`, plus metrics wiring. At the end of this milestone the API compiles and is exported; nothing calls it yet.

In `keiro/src/Keiro/Inbox/Types.hs`, add two types and export them. `DelegatedOutcome` is the witness a delegated handler must return; give it a haddock stating the contract in one breath — construct `DelegatedDuplicate` only from a downstream duplicate signal, never speculatively:

```haskell
-- | The delegated handler's report of what its downstream state machine
-- observed. 'DelegatedDuplicate' must be constructed only by folding a
-- downstream duplicate signal ('DuplicateEvent' from the store,
-- 'PMCommandDuplicate' from dispatch, an already-seeded workflow
-- instance) — it is the inbox's only evidence that dedupe happened.
data DelegatedOutcome a
    = DelegatedFresh !a
    | DelegatedDuplicate
    deriving stock (Generic, Eq, Show)

-- | Which mechanism guarantees at-most-once handler effects for an
-- intake. 'IdempotenceInboxTable' is the classic keiro_inbox row;
-- 'IdempotenceDelegated' trusts the handler's own state machine.
data InboxIdempotence
    = IdempotenceInboxTable
    | IdempotenceDelegated
    deriving stock (Generic, Eq, Show)
```

`InboxIdempotence` exists so the DSL scaffold (M4) has a live enum to lower onto, mirroring how `inboxDedupePolicy` lowers onto `InboxDedupePolicy`.

In `keiro/src/Keiro/Inbox.hs`, add three exported functions. The single-message base variant computes the key, runs the handler, classifies, records metrics. Note the constraint set: `IOE` only — the wrapper does no store work. The module haddock must spell out the two-part **delegation contract**: (1) *identity absorption* — the handler must derive its downstream identity (event id / workflow id) from the dedupe key it is given, so a redelivery lands on the same identity; (2) *effect confinement* — every effect of the handler must be inside the transaction guarded by that identity (inline projections and outbox enqueues already ride the append transaction; anything else is unguarded on duplicates).

```haskell
runInboxDelegated ::
    forall a es.
    (IOE :> es) =>
    Maybe KeiroMetrics ->
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es (Either InboxError (InboxResult a))
```

Implementation shape: `dedupeKeyFor policy event kafka` — `Left err` short-circuits exactly as today; on `Right dedupe`, run `handler dedupe event`, map `DelegatedFresh a -> InboxProcessed a` and `DelegatedDuplicate -> InboxDuplicate`, then reuse the existing `recordInboxResult mMetrics Nothing`. Exceptions from the handler propagate (same as `runInboxTransaction`); the caller's ack layer maps them to redelivery.

The retrying variant replaces the Postgres attempt ledger with a caller-supplied delivery attempt (from the consumer's redelivery counter or a broker delivery-attempt header):

```haskell
runInboxDelegatedWithRetries ::
    forall a es.
    (IOE :> es) =>
    Maybe KeiroMetrics ->
    Int ->  -- ^ attempt ceiling
    Int ->  -- ^ this delivery's attempt number, 1-based, from the Kafka layer
    InboxDedupePolicy ->
    IntegrationEvent ->
    Maybe KafkaDeliveryRef ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es (Either InboxError (InboxResult a))
```

Semantics, mirroring `runInboxTransactionWithRetries` as closely as the missing table allows: if `attempt > attemptCeiling`, return `InboxPreviouslyFailed Nothing` without running the handler (the consumer's disposition maps it to dead-letter — in delegated mode the DLQ topic, not a failed row, is the dead-letter record). Otherwise `trySync` the handler; on exception return `InboxHandlerFailed (Text.pack (displayException err)) attempt` and record via `recordInboxResult mMetrics (Just attemptCeiling)` so the poisoned counter fires at the ceiling exactly as today.

The batch variant reuses the existing pure planner. Extract the current `planInboxBatch`/`BatchPlan` so both paths share it; the delegated batch simply never opens a transaction of its own:

```haskell
runInboxDelegatedBatch ::
    forall a es.
    (IOE :> es) =>
    Maybe KeiroMetrics ->
    InboxDedupePolicy ->
    [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es [Either InboxError (InboxResult a)]
```

Results in input order: `BatchKeyError err -> Left err`, `BatchDuplicate -> Right InboxDuplicate` (in-batch repeat, handler not run), `BatchWork -> ` run the handler and classify. There is no batch-transaction fallback dance because there is no batch transaction — each handler invocation owns its own commit scope, and one poison message cannot poison batch mates by construction. Note this in the haddock: the *commit amortization* that `runInboxTransactionBatch` provides is the handler's own business in delegated mode (e.g. batching appends), not the inbox's.

Acceptance: `just haskell-build` compiles the new exports; no behavior change anywhere else (`cabal test keiro-test` still green).


### Milestone 2 — Downstream adapters: folding duplicate signals into the witness

Scope: a new module `keiro/src/Keiro/Inbox/Delegated.hs` (add to `keiro.cabal`'s `exposed-modules`) with the helpers that make the witness easy to construct correctly for the three supported state machines. Nothing in `keiro/src` imports `Keiro.Inbox`, so importing `Keiro.Command`, `Keiro.ProcessManager`, and `Keiro.Workflow.*` here creates no cycle (verified during planning).

First, identity absorption made concrete — the deterministic id recipe, mirroring `deterministicCommandId`'s v5-UUID construction but namespaced to delegated intake:

```haskell
-- | Stable event id for a delegated intake's append, derived from
-- (consumer name, dedupe key, emit index) via a v5 UUID. The same
-- delivery always yields the same id, so the store's uniqueness
-- constraint collapses redeliveries.
delegatedEventId :: Text -> Text -> Int -> EventId
```

Join `["keiro", "inbox-delegated", consumerName, dedupeKey, show emitIndex]` with `":"` and hash with `UUID.V5.generateNamed UUID.V5.namespaceURL`, byte-for-byte the same technique as `deterministicCommandId` in `keiro/src/Keiro/ProcessManager.hs`.

Then three folds:

```haskell
-- | Classify a 'Keiro.Command.runCommand' result: a store-level
-- duplicate-id rejection is the state machine saying "already applied".
-- All other errors stay errors (Left) for the caller to map to
-- retry/dead-letter.
delegatedFromCommand ::
    Either CommandError (CommandResult target) ->
    Either CommandError (DelegatedOutcome (CommandResult target))

-- | Classify a process-manager/router dispatch result.
delegatedFromPMCommand ::
    PMCommandResult target ->
    DelegatedOutcome (PMCommandResult target)

-- | Seed-or-detect for workflows: an existing keiro_workflows instance
-- row means this identity was already seeded; otherwise run the
-- workflow. The lookup-then-run pair is not atomic — two concurrent
-- first deliveries can both observe no row and both call 'runWorkflow';
-- the journal's append-if-absent still makes effects exactly-once, and
-- the second run merely classifies as Fresh. Document, don't fight it.
delegatedWorkflowStart ::
    (IOE :> es, Store :> es) =>
    WorkflowName ->
    WorkflowId ->
    Eff (Workflow : es) a ->
    Eff es (DelegatedOutcome (WorkflowOutcome a))
```

`delegatedFromCommand` pattern-matches `Left (StoreFailed (DuplicateEvent _)) -> Right DelegatedDuplicate`; `delegatedFromPMCommand` maps `PMCommandDuplicate _ -> DelegatedDuplicate` and every other constructor to `DelegatedFresh`. `delegatedWorkflowStart` is `lookupInstance name wid >>= maybe (DelegatedFresh <$> runWorkflow name wid action) (const (pure DelegatedDuplicate))`.

Acceptance: builds; haddocks on every export state which duplicate signal each fold consumes.


### Milestone 3 — Behavior tests against a live store

Scope: a new `describe "Keiro.Inbox delegated"` block in `keiro/test/Main.hs`, `around (withFreshStore fixture)` like the existing inbox block. These tests are the demonstrable-behavior anchor of the whole plan.

Test (a), aggregate twice-delivery: build an integration event with a fixed `messageId`; the handler dispatches a command to a test aggregate via `runCommand` with `eventIds = [delegatedEventId "test-consumer" dedupe 0]` and folds through `delegatedFromCommand`. Deliver twice via `runInboxDelegated`. Assert first result `Right (InboxProcessed _)`, second `Right InboxDuplicate`, the target stream contains exactly one appended event, and — the headline — `listInbox "<source>"` returns `[]` (the inbox table was never touched). Reuse whichever minimal test aggregate the existing command-cycle specs in this file already define rather than inventing a new one.

Test (b), workflow twice-delivery: handler is `delegatedWorkflowStart` with `WorkflowId` derived from the dedupe key; a journaled step increments a counter table. Two deliveries: first `InboxProcessed`, second `InboxDuplicate`, counter is 1, `listInbox` empty.

Test (c), batch: three deliveries where two share a `messageId`; `runInboxDelegatedBatch` returns, in input order, `Processed`, `Duplicate` (in-batch suppression — handler ran twice total, verify via counter), `Processed`.

Test (d), retries and poison: a handler that always throws. With ceiling 3, attempts 1 and 2 return `InboxHandlerFailed _ n` with the supplied attempt number; attempt 4 (`> ceiling`) returns `InboxPreviouslyFailed Nothing` without invoking the handler (assert via an `IORef` invocation counter). With a metrics handle installed (the existing inbox metrics specs show the harness), assert the poisoned counter increments exactly once at the ceiling.

Test (e), key-policy failure: `PreferSourceEventIdentity` on an envelope lacking source identity returns `Left (DedupePolicyUnsatisfied _)` without running the handler — the delegated path must preserve the table path's error surface.

Acceptance: `cabal test keiro-test` green from the repo root. This milestone plus M1/M2 is a shippable runtime feature; commit history should reflect that (`feat(inbox): …` commits with the trailers listed under Concrete Steps).


### Milestone 4 — DSL: spec syntax, scaffold, and diff gating

Scope: the `.keiro` spec owns the idempotence mode, and changing it (or the dedupe identity) is gated as Breaking. All files under `keiro-dsl/`.

Grammar (`src/Keiro/Dsl/Grammar.hs`): add `data IdempotenceMode = IdemInboxTable | IdemDelegated` and a field `inkIdempotence :: !IdempotenceMode` to `IntakeNode`.

Parser (`src/Keiro/Dsl/Parser.hs`): in `pIntake`, accept an optional clause after the `dedupe` line — `idempotence table` or `idempotence delegated` — defaulting to `IdemInboxTable` when absent so every existing spec parses unchanged. Reserve the new keywords (`idempotence`, `table`, `delegated`) in the reserved-word list alongside `dedupe`/`disposition`; check first that `table` is not already reserved by another vertical, and if collision is a problem use `inbox-table` as the literal. PrettyPrint (`src/Keiro/Dsl/PrettyPrint.hs`): print the clause (always print it explicitly, even for the default, or omit-when-default — match whichever convention the printer uses for other optional clauses; the parser/printer round-trip test in `keiro-dsl-test` will catch a mismatch). Skeleton (`src/Keiro/Dsl/Skeleton.hs`, `intakeSkeleton`): emit `idempotence table` with a one-line comment naming the alternative.

Scaffold (`src/Keiro/Dsl/Scaffold.hs`, `emitIntakeGen`): alongside `inboxDedupePolicy`, emit

```haskell
inboxIdempotence :: InboxIdempotence
inboxIdempotence = IdempotenceInboxTable  -- or IdempotenceDelegated, per spec
```

importing `InboxIdempotence (..)` from `Keiro.Inbox.Types`. When the mode is delegated, also emit a comment above the `InboxInProgress` and `InboxPreviouslyFailed` disposition cases stating they are unreachable at runtime in delegated mode and retained for totality. The disposition table itself and the seven-outcome completeness rule in `validateIntake` stay exactly as they are (Decision Log).

Diff (`src/Keiro/Dsl/Diff.hs` + `src/Keiro/Dsl/Validate.hs`): add two `DiagnosticCode` constructors, `IntakeIdempotenceModeChanged` and `IntakeIdentitySchemeChanged`. Add `intakeDiff :: Spec -> IntakeNode -> [Change]` that finds the same-named intake in the old spec and emits `breaking` for: `inkIdempotence` changed (mode flip — delivery semantics change), `inkDedupePolicy` changed, or `inkDedupeKey` changed (identity scheme change — in-flight messages dedupe differently). A brand-new intake is `additive`. Wire it into `diffSpecs` next to the aggregate walk. Follow the existing `breaking`/`additive` helper idiom (`breaking n subj code detail`).

Tests (`keiro-dsl/test/`, suite `keiro-dsl-test`): a new fixture `test/fixtures/intake-delegated.keiro` (copy `intake.keiro`, add `idempotence delegated`); parser test that it parses with `inkIdempotence = IdemDelegated` and that `intake.keiro` (no clause) defaults to `IdemInboxTable`; round-trip test through PrettyPrint; validator test that the delegated fixture is diagnostic-clean; diff tests asserting mode flip, policy change, and key change each produce a `Breaking` with the right code, and that an unchanged spec produces none.

Acceptance: `cabal test keiro-dsl-test` green; `cabal run keiro-dsl -- check keiro-dsl/test/fixtures/intake-delegated.keiro` exits 0 (adjust invocation to the CLI's actual argument shape in `keiro-dsl/app/Main.hs`).


### Milestone 5 — Delegated conformance fixture against the live runtime

Scope: prove the generated surface and a hand-filled delegated runner type-check against the real `keiro` API, the same way the existing intake fixtures do.

Add to `keiro-dsl/test/conformance-intake-full/`: a Generated module `Generated/HospitalCapacity/IncidentInboxDelegated/Inbox.hs` (what `scaffold` would emit for the delegated fixture: `inboxDedupePolicy`, `inboxIdempotence = IdempotenceDelegated`, `inboxDisposition` with the unreachable-case comments) and a hand-filled `HospitalCapacity/IncidentInboxDelegated/Integration.hs` whose runner wires `runInboxDelegated Nothing inboxDedupePolicy` and whose handler demonstrates the aggregate fold: derive `delegatedEventId`, call a command, classify via `delegatedFromCommand`. Register both in the `keiro-dsl-conformance-intake-full` stanza's `other-modules` in `keiro-dsl/keiro-dsl.cabal`; extend that suite's `Main.hs` with pure assertions on `inboxIdempotence` and the disposition table, mirroring the existing `conformance-intake-runtime` assertions. If the scaffolder's output for the delegated fixture and this hand-written Generated module drift, the conformance suite is the tripwire — regenerate with `keiro-dsl scaffold` against `intake-delegated.keiro` and diff to confirm they match.

Acceptance: `cabal test keiro-dsl-conformance-intake-runtime keiro-dsl-conformance-intake-full` green.


### Milestone 6 — Benchmarks and documentation

Scope: quantify the win honestly and teach users when (not) to use the mode.

Bench (`keiro/bench/Main.hs`): add `inbox.delegated-single` and `inbox.delegated-batch-100`. To compare like with like, both the table-backed comparator (`inbox.single-nometrics`) and the delegated scenario must do the same downstream work: give the delegated handler a single-statement transaction inserting into a scratch table with the dedupe key as primary key (the moral equivalent of a deterministic-id append), and note in a comment that the table scenario performs the identical handler statement *plus* the `keiro_inbox` insert. Extend the `InboxScenario` record (or add a sibling) as needed. Run before/after:

```bash
cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --csv bench-after-inbox.csv"
```

Record the table in Outcomes & Retrospective with the explicit caveat that single-message wall time is commit-dominated, so expect a modest delta there; the structural win (no row growth, no unique-index churn, no GC) should be stated in prose next to the numbers, not claimed as latency. Regenerate `keiro/bench/baseline-inbox.csv` to include the new scenarios so `just bench-regression` keeps passing (it pattern-matches `-p inbox`).

Docs: in `docs/user/integration-events.md`, add a "Delegated idempotence" subsection after the message-identity section: when the table is redundant, the delegation contract (identity absorption, effect confinement), the witness type, what you give up (no `keiro_inbox` dead-letter rows, no `listInbox`/backlog visibility for these consumers, retry accounting moves to the Kafka layer/DLQ topic), and a worked handler snippet using `delegatedEventId` + `delegatedFromCommand`. Touch `docs/guides/integration-events-with-kafka.md` with a pointer. In `docs/corpus/keiro-dsl-corpus.md`, document the `idempotence` clause and the new Breaking diff rules.

Acceptance: `just haskell-verify` green (build + all tests + website build, which validates the docs render); bench table recorded.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro` (adjust to your checkout path).

Build and test loop while implementing:

```bash
just haskell-build                 # cabal build all
cabal test keiro-test              # runtime hspec (spins its own template-DB Postgres fixture)
cabal test keiro-dsl-test          # DSL parser/validator/diff specs
cabal test keiro-dsl-conformance-intake-runtime keiro-dsl-conformance-intake-full
```

Expected shape of a passing runtime test run (hspec summary line):

```text
... examples, 0 failures
Test suite keiro-test: PASS
```

To run only the new inbox specs while iterating:

```bash
cabal test keiro-test --test-options='--match "Keiro.Inbox delegated"'
```

Bench (M6, manual/local — the baseline reflects the primary dev machine):

```bash
cabal bench keiro-bench --benchmark-options="-p inbox --time-mode wall --csv bench-after-inbox.csv"
just bench-regression
```

DSL CLI smoke checks (M4; confirm exact argument shape against `keiro-dsl/app/Main.hs`):

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/intake-delegated.keiro
cabal run keiro-dsl -- diff --since HEAD~1 <path-to-spec>   # non-zero exit on Breaking
```

Commit style: Conventional Commits, small and working at every step — suggested sequence `feat(inbox): add DelegatedOutcome witness and delegated intake entry points` (M1), `feat(inbox): add downstream duplicate-signal adapters` (M2), `test(inbox): cover delegated intake against live store` (M3), `feat(dsl): spec-level idempotence mode with breaking-change diff gating` (M4), `test(dsl): delegated intake conformance fixture` (M5), `perf(inbox): benchmark delegated intake` + `docs(inbox): document delegated idempotence` (M6). Every commit body must end with both trailers:

```text
ExecPlan: docs/plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md
Intention: intention_01kwganm3be0q8z4g6rmcqdj05
```


## Validation and Acceptance

The feature is accepted when the following behaviors are observable, in this order of importance.

Delivering the same integration event twice through `runInboxDelegated` with an aggregate-appending handler yields `Right (InboxProcessed _)` then `Right InboxDuplicate`, the aggregate stream holds the appended event exactly once, and `listInbox` for that source returns the empty list — proving both exactly-once effects and zero `keiro_inbox` writes (M3 test (a); run `cabal test keiro-test`).

The workflow, batch, retries/poison, and policy-error behaviors described in Milestone 3 all pass in the same suite, and the poisoned-messages counter fires exactly once at the attempt ceiling with a metrics handle installed.

A `.keiro` intake spec carrying `idempotence delegated` parses, validates cleanly, round-trips through the pretty-printer, and scaffolds a Generated module exporting `inboxIdempotence = IdempotenceDelegated`; editing a spec's idempotence mode, dedupe policy, or dedupe key field and running the diff produces a `Breaking` change and a non-zero exit (`cabal test keiro-dsl-test` covers all of this; the CLI smoke commands above demonstrate it interactively).

The delegated conformance fixture compiles against the live runtime (`cabal test keiro-dsl-conformance-intake-full`), so any future signature drift in `runInboxDelegated` or the adapters breaks the DSL's build, exactly as the existing table-backed fixture guards `runInboxTransaction`.

`just bench-regression` passes against the regenerated `keiro/bench/baseline-inbox.csv`, and the Outcomes section contains the before/after table for `inbox.delegated-single` vs `inbox.single-nometrics` with the honest commit-dominated framing.

`just haskell-verify` is green at the end (build, all test suites, website build including the edited docs).


## Idempotence and Recovery

Every step is additive and re-runnable. No migration touches the database; the `keiro_inbox` table, its schema, and all existing entry points are unchanged, so partial implementation cannot break existing consumers — the new functions simply sit unused until called. Re-running `keiro-dsl scaffold` overwrites Generated modules by design (they are marked `@generated`; hand-filled modules are never overwritten). Regenerating the bench baseline is safe to repeat; if bench numbers drift on a different machine, re-record rather than force — the baseline is documented as primary-dev-machine-specific and the guard is manual, not CI. If a milestone must be rolled back, revert its commits; no state outlives the code.

One semantic risk to keep in view rather than recover from: delegated mode is only correct under the delegation contract (identity absorption + effect confinement). The witness type, the adapters, the haddocks, the docs section, and the DSL diff gate all exist to keep a consumer from drifting out of that contract silently. Do not weaken any of them to save time.


## Interfaces and Dependencies

No new external dependencies; everything builds on packages already in `keiro.cabal` (`uuid` for v5 ids — already used by `Keiro.ProcessManager` — `effectful`, `hasql-transaction`) and `keiro-dsl.cabal`.

At the end of M1, `Keiro.Inbox.Types` additionally exports `DelegatedOutcome (..)` and `InboxIdempotence (..)`, and `Keiro.Inbox` exports:

```haskell
runInboxDelegated ::
    (IOE :> es) =>
    Maybe KeiroMetrics -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es (Either InboxError (InboxResult a))

runInboxDelegatedWithRetries ::
    (IOE :> es) =>
    Maybe KeiroMetrics -> Int -> Int -> InboxDedupePolicy -> IntegrationEvent -> Maybe KafkaDeliveryRef ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es (Either InboxError (InboxResult a))

runInboxDelegatedBatch ::
    (IOE :> es) =>
    Maybe KeiroMetrics -> InboxDedupePolicy -> [(IntegrationEvent, Maybe KafkaDeliveryRef)] ->
    (Text -> IntegrationEvent -> Eff es (DelegatedOutcome a)) ->
    Eff es [Either InboxError (InboxResult a)]
```

At the end of M2, `Keiro.Inbox.Delegated` (new exposed module) exports:

```haskell
delegatedEventId :: Text -> Text -> Int -> EventId
delegatedFromCommand :: Either CommandError (CommandResult t) -> Either CommandError (DelegatedOutcome (CommandResult t))
delegatedFromPMCommand :: PMCommandResult t -> DelegatedOutcome (PMCommandResult t)
delegatedWorkflowStart :: (IOE :> es, Store :> es) => WorkflowName -> WorkflowId -> Eff (Workflow : es) a -> Eff es (DelegatedOutcome (WorkflowOutcome a))
```

At the end of M4, `Keiro.Dsl.Grammar` exports `IdempotenceMode (..)` and `IntakeNode` carries `inkIdempotence :: !IdempotenceMode`; `Keiro.Dsl.Validate.DiagnosticCode` carries `IntakeIdempotenceModeChanged` and `IntakeIdentitySchemeChanged`; `Keiro.Dsl.Diff` exports (or internally wires) `intakeDiff` through `diffSpecs`.

Module-dependency note recorded for the implementer: `Keiro.Inbox.Delegated` imports `Keiro.Command`, `Keiro.ProcessManager`, `Keiro.Workflow`, `Keiro.Workflow.Instance`, and `Keiro.Inbox.Types`; as of planning, nothing under `keiro/src` imports any `Keiro.Inbox*` module except the inbox modules themselves and `Keiro.Telemetry` (which imports only `Keiro.Inbox.Kafka` for a type), so no import cycle is possible.
