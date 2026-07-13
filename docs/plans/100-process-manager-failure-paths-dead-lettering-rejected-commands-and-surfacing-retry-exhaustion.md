---
id: 100
slug: process-manager-failure-paths-dead-lettering-rejected-commands-and-surfacing-retry-exhaustion
title: "Process-manager failure paths: dead-lettering rejected commands and surfacing retry exhaustion"
kind: exec-plan
created_at: 2026-07-12T05:07:53Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
master_plan: "docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md"
---

# Process-manager failure paths: dead-lettering rejected commands and surfacing retry exhaustion

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, when a process manager (keiro's saga primitive) dispatches a command that the
target aggregate rejects, the worker halts the whole subscription — and because a halt
deliberately does not advance the delivery checkpoint, the same event is redelivered on
restart, the same command is re-dispatched, rejected again, and the subscription is
permanently wedged. Worse, the manager's own state stream already recorded "I reacted to
this event" before the dispatch failed, so the saga's durable history claims an action
happened that never did. Separately, when a transient failure (say, a database outage)
outlasts the bounded retry ladder, kiroku silently records the *source event* in a
dead-letter table and moves on — dropping input from the process manager forever — while
keiro's documentation claims transient failures simply "retry", with no bound mentioned
and no replay story.

After this plan, an operator can: (1) configure a rejected-command policy on process
managers and routers — halt (the default, unchanged), dead-letter (persist a durable,
queryable record of the rejected dispatch and move on), or skip (count and move on) —
so a benign business rejection can no longer wedge a subscription; (2) see every
dead-lettered dispatch in a new `keiro.keiro_dead_letters` table carrying the source
event, the dispatcher, the correlation key, the target stream, and the typed error
class; (3) see retry exhaustion when it happens, via a documented observability hook
and a keiro metric, instead of a silent checkpoint advance; and (4) replay kiroku's
dead-lettered source events through the same handler with a one-call operator function
that is idempotent by construction. To see it working: run
`cabal test keiro-test` from the repository root — the new end-to-end tests exercise a
rejected dispatch that dead-letters and lets the next event through, a forced
retry-exhaustion that lands in `kiroku.dead_letters` and fires the metric, and a replay
that produces only benign duplicates.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-13 17:15Z) Baseline: `cabal build all` and `cabal test keiro-test` passed (316 examples, 0 failures)
- [x] (2026-07-13 17:22Z) M1: `keiro_dead_letters` migration authored via `keiro-migrate -- new`, manifest checked, `keiro-migrations-test` green (10 examples, 0 failures)
- [x] (2026-07-13 17:22Z) M1: `Keiro.DeadLetter.Schema` statements (insert idempotent, list) written and unit-tested
- [x] (2026-07-13 17:22Z) M1: `Keiro.DeadLetter` typed API (`DispatchDeadLetter`, `recordDispatchDeadLetter`, `listDispatchDeadLetters`) exported; `keiro-test` green (317 examples, 0 failures)
- [x] (2026-07-13 17:35Z) M2: `PMCommandFailed` carries the target stream name; call sites and existing tests updated
- [x] (2026-07-13 17:35Z) M2: `RejectedCommandPolicy` added to `WorkerOptions` (default `RejectedHalt`); shared `decideForFailures` classification extracted
- [x] (2026-07-13 17:35Z) M2: process-manager worker wired: dead-letter write + `AckOk` under `RejectedDeadLetter`; manager-state rejection covered (emit index -1)
- [x] (2026-07-13 17:35Z) M2: router worker wired to the same policy
- [x] (2026-07-13 17:35Z) M2: `keiro.dispatch.deadlettered` counter added to `Keiro.Telemetry`
- [x] (2026-07-13 17:35Z) M2: end-to-end tests cover row + ack + subsequent processing, default halt, skip, router parity, manager-state rejection, and redelivery idempotency; `keiro-test` passes 322 examples
- [x] (2026-07-13 17:35Z) M2: saga-history divergence documented in `Keiro.ProcessManager` haddock
- [x] (2026-07-13 17:47Z) M3: retry-bound documentation corrected in `Keiro.ProcessManager` and `Keiro.Router` haddocks (bound, knob, consequence, per-path behavior)
- [x] (2026-07-13 17:47Z) M3: `Keiro.Telemetry.kirokuEventBridge` helper + `keiro.subscription.deadlettered` counter
- [x] (2026-07-13 17:47Z) M3: retry-exhaustion visibility test (RetryPolicy 2 through the ack bridge; dead-letter row, metric, checkpoint advance, next event delivered)
- [x] (2026-07-13 17:47Z) M3: adapter `retryPolicy` gap and EP-96 shard-path integration expectations recorded; `cabal build all` and the 323-example Keiro suite pass
- [x] (2026-07-13 17:57Z) M4: `Keiro.DeadLetter.Replay` (`listSubscriptionDeadLetters`, `replaySubscriptionDeadLetters`) implemented with opaque-cursor-safe source lookup
- [x] (2026-07-13 17:57Z) M4: replay idempotency tests pass (already-processed replay yields duplicates only; unprocessed replay applies once and deduplicates on rerun); full suite passes 325 examples
- [x] (2026-07-13 18:01Z) M5: cross-stream correlation ordering and per-write transaction boundaries documented in `Keiro.ProcessManager`, with router cross-reference and passing Haddock build
- [ ] Final: `just verify` green; Outcomes & Retrospective written; masterplan Progress updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Findings from plan-authoring research (2026-07-12), each verified against source:

- Shibuya's `DeadLetterReason` is a closed, text-only sum (`PoisonPill Text`,
  `InvalidPayload Text`, `MaxRetriesExceeded` — see the kiroku repository,
  `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`, `toKirokuDeadLetterReason`,
  lines 156-160). kiroku's structured `DeadLetterOther Text Value` constructor is therefore
  unreachable through the Shibuya ack path. This ruled out reusing `kiroku.dead_letters`
  for rejected-command records via `AckDeadLetter` (Decision Log).
- The `shibuya-kiroku-adapter`'s `KirokuAdapterConfig` does not expose kiroku's
  `retryPolicy` field at all (compare `KirokuAdapterConfig` at
  `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:180-229` with
  `SubscriptionConfigM.retryPolicy` at
  `kiroku-store/src/Kiroku/Store/Subscription/Types.hs:281-286`). On the adapter path the
  retry bound is always the default 5 and cannot be tuned by a keiro consumer today.
- kiroku already emits `KirokuEventSubscriptionDeadLettered` on every dead-letter write
  (`kiroku-store/src/Kiroku/Store/Subscription/Worker.hs`, `writeDeadLetter`), and both
  `kiroku-metrics` (Prometheus counter `kiroku_subscriptions_dead_lettered_total`,
  `kiroku-metrics/src/Kiroku/Metrics/Collector.hs:206-207`) and `kiroku-otel`
  (`kiroku-otel/src/Kiroku/Otel/Subscription.hs:301`) already consume it. Surfacing
  exhaustion is mostly a wiring-and-documentation problem, not new plumbing.
- Appending a keiro-side "dispatch dead-lettered" marker event to the process manager's
  own stream is architecturally unsound, not merely inconvenient: the manager's stream is
  replayed through its keiki transducer on every hydration, and a foreign event the
  transducer has no edge for would stall replay and surface as `HydrationReplayFailed`
  (`keiro/src/Keiro/Command.hs:121-124`) — turning one failed dispatch into a permanently
  unhydratable saga. Documentation plus the dead-letter record is the only honest v1
  (Decision Log).

- The migration manifest already contained the schema-management canary as
  migration 0017, so the authoring CLI allocated `0018.sql` rather than the
  plan's authoring-time 0017 estimate. The native migration suite correctly
  required its manifest/count and post-Codd-import pending-migration assertions
  to advance from 17/25 to 18/26. Evidence: `keiro-migrations-test` passes all
  10 examples with the new migration applied and verified.
- EP-96 is already complete in the live tree. `ShardedWorkerOptions` contains
  `retryPolicy`, `runShardedSubscriptionGroupAck` consumes a per-event
  `ShardDelivery`, and `ShardAckRetry` / `ShardAckDeadLetter` map to Kiroku's
  bounded `SubscriptionResult`. EP-100 therefore consumes this delivered
  surface; it does not need the plan's old conditional integration fallback.
- `commandErrorClass` already encoded EP-99's low-cardinality taxonomy but was
  private to `Keiro.Command`. EP-100 exports that existing function and uses it
  for dead-letter rows; duplicating the pattern match in the coordination layer
  would let span and dead-letter classifications drift.
- The exported `subscriptionAckStream` is the common retry primitive beneath
  both the Shibuya adapter and EP-96's shard worker. Exercising it directly let
  the M3 test set `RetryPolicy 2` without reproducing the adapter's envelope
  conversion, while still covering the exact checkpoint, retry, dead-letter,
  and `eventHandler` path used in production.
- Kiroku's current `GlobalPosition` contract explicitly forbids cursor
  arithmetic and does not promise dense positions. The authored replay sketch's
  `deadLetterGlobalPosition - 1` lookup would therefore have violated the live
  dependency API. Kiroku also has no exported exact event-id/position point
  read, so replay now scans `$all` backward once per batch, advancing only with
  positions returned by Kiroku and matching both stored id and position.
- The authored M5 sketch said a retry could let another event overtake it even
  on an unsharded subscription. Kiroku's live `processEvents` loop instead
  retries one event in place before advancing the batch, so an unsharded worker
  remains serial. Cross-stream nondeterminism still exists because independent
  appends race for global order, and sharded members process different source
  streams concurrently; the delivered Haddock makes that distinction.


## Decision Log

Record every decision made while working on the plan.

- Decision: rejected-command dead-letter records live in a keiro-owned table
  `keiro.keiro_dead_letters` (new migration in `keiro-migrations/`), not in kiroku's
  `kiroku.dead_letters`.
  Rationale: three independent reasons. (1) Grain mismatch — kiroku's table records "this
  SOURCE EVENT was abandoned by a subscription" (one row per event, checkpoint advances
  atomically with the insert), while EP-100's record is "this DISPATCHED COMMAND was
  rejected": one source event can dispatch several commands of which only some are
  rejected, and the source event itself is *successfully acked* after the record is
  written. (2) The only write path into `kiroku.dead_letters` from a keiro worker is
  Shibuya's `AckDeadLetter`, whose reason type is text-only (see Surprises & Discoveries),
  so the structured fields (dispatcher, correlation, target stream, error class) would be
  smuggled as an encoded string. (3) Schema ownership — keiro's framework tables live in
  the dedicated `keiro` schema (masterplan 14 context; see
  `keiro-migrations/migrations/0001-keiro-bootstrap.sql`), and keiro never writes kiroku's
  tables directly. kiroku's table keeps its existing role: source events abandoned by the
  subscription machinery (retry exhaustion, poison), which Milestone 4's replay tooling
  reads.
  Date: 2026-07-12

- Decision: the dead-letter record stores the target stream name, the low-cardinality
  error class (`commandErrorClass`), and the rendered `CommandError` — NOT the command
  value itself.
  Rationale: the dispatched command type `targetCi` has no codec in general (keiro's
  `EventStream` codecs cover events, not command inputs; `EncodeFailed` only exists for
  emitted events), so persisting the command would force a new serialization obligation
  onto every process-manager author for a diagnostic record. The source event reference
  (`source_event_id`, `source_global_position`) plus the dispatcher name and emit index
  fully determine the command anyway: `handle` is pure
  (`keiro/src/Keiro/ProcessManager.hs:96-99,111`), so re-running it on the source event
  reproduces the identical command — that is the same determinism the idempotency ids
  rely on.
  Date: 2026-07-12

- Decision: the default policy remains `RejectedHalt`; dead-lettering is opt-in.
  Rationale: halting is loud and lossless — the event replays on restart and an operator
  cannot miss a stopped subscription. Dead-lettering by default would silently accept
  saga-history divergence (the manager's state stream records a reaction whose command
  never applied) in deployments that have no monitoring on the new table. The Router
  documentation already frames benign rejections as a modeling duty (total transitions,
  `keiro/src/Keiro/Router.hs:192-195`); the policy is the deliberate escape hatch for
  domains where rejection is genuinely data-dependent, and choosing it should be a
  conscious act paired with monitoring.
  Date: 2026-07-12

- Decision: the policy covers rejection-class errors only (`CommandRejected` today, plus
  the rejection/ambiguity constructors EP-99 introduces when it lands); other
  non-transient errors (`HydrationDecodeFailed`, `HydrationReplayFailed`, `EncodeFailed`,
  non-transient `StoreFailed`) always halt regardless of policy.
  Rationale: a rejection is the target machine saying "no edge matches this command in
  this state" — a per-command, data-dependent outcome that dead-letters meaningfully. The
  others are systemic faults (corrupted stream, broken codec): under a dead-letter policy
  they would dead-letter every subsequent event behind the same fault, converting a loud
  stop into a silent total outage. Ambiguity (post-EP-99) follows the rejection policy
  because distinguishing "ambiguous guards" from "no matching edge" in the dead-letter
  row is precisely the diagnostic value masterplan 14's dependency graph assigns this
  plan; until EP-99 lands, both render as `command_rejected`.
  Date: 2026-07-12

- Decision: saga-history divergence is addressed by documentation plus the dead-letter
  record; keiro does not append any marker event to the manager's stream.
  Rationale: see Surprises & Discoveries — a foreign event would break the manager's own
  transducer replay (`HydrationReplayFailed`). The honest contract is: a dead-lettered
  dispatch means the manager stream recorded a reaction whose command never applied; the
  compensating pattern (the PM author models a `DispatchFailed`-style command/event in
  their own transducer and an operator or automation drives it from the dead-letter
  table) is documented in the module haddock, and the dead-letter row is the durable
  witness that makes the runbook possible.
  Date: 2026-07-12

- Decision: `PMCommandFailed` gains the resolved target stream name
  (`PMCommandFailed !StreamName !CommandError`), a breaking change to a public
  constructor shared by `Keiro.ProcessManager` and `Keiro.Router`.
  Rationale: the worker's ack layer must write dead-letter rows naming the target stream,
  but today the failure constructor carries only the error
  (`keiro/src/Keiro/ProcessManager.hs:142-146`). The stream name is already computed at
  every dispatch site (`targetStreamName`, ProcessManager.hs:325, Router.hs:156). The
  emit index is recovered from list position — `commandResults` is documented as "in
  order" (ProcessManager.hs:157-160) and both dispatch loops `zip [0..]`.
  Date: 2026-07-12

- Decision: no cross-schema foreign key from `keiro.keiro_dead_letters.source_event_id`
  to `kiroku.events`.
  Rationale: keiro's migrations must not depend on kiroku's physical schema layout
  (`keiro-migrations` declares a logical dependency on the kiroku component and composes
  after it, but the keiro schema separation exists precisely so neither side's DDL
  references the other's tables). The uniqueness key
  `(dispatcher_name, source_event_id, emit_index)` gives idempotent inserts without any
  FK.
  Date: 2026-07-12

- Decision: replay tooling replays kiroku dead letters by re-running the caller-supplied
  handler and relies on the deterministic-id dedup for safety; rows are left in place
  after replay.
  Rationale: every process-manager write id is a v5 UUID of
  `(name, correlation, source event id, emit index)`
  (`keiro/src/Keiro/ProcessManager.hs:229-243`), pre-checked with `eventAlreadyIn`
  (:280, :326) and backstopped by folding the store's `DuplicateEvent` rejection into a
  benign duplicate (:292-296, :339-340). Re-running the handler on the same source event
  therefore appends nothing new — replay is idempotent by construction, so replaying an
  already-replayed (or concurrently processed) row is harmless, and no "resolved" marker
  is needed. `kiroku.dead_letters` is kiroku-owned; keiro does not delete or update its
  rows. Operators prune by `created_at` if desired.
  Date: 2026-07-12

- Decision: the adapter-path retry bound stays at kiroku's default 5 in this plan; the
  missing `retryPolicy` knob on `KirokuAdapterConfig` is documented as a known limitation
  with an upstream note, not fixed here.
  Rationale: masterplan 14 scopes out "changes to kiroku beyond consuming APIs it already
  exports", and the `shibuya-kiroku-adapter` package lives in the kiroku repository. The
  keiro-owned shard path (post-EP-96) gets the knob because keiro builds that
  `SubscriptionConfig` itself (`keiro/src/Keiro/Subscription/Shard/Worker.hs:256-261`).
  Date: 2026-07-12

- Decision: new counter names are `keiro.dispatch.deadlettered` (rejected dispatches
  dead-lettered by policy) and `keiro.subscription.deadlettered` (kiroku source-event
  dead-letters observed through the event bridge).
  Rationale: follows the existing dotted convention and the `keiro.dispatch.*` family
  (`keiro/src/Keiro/Telemetry.hs:565-569`); avoids the names masterplan 14's Integration
  Point 3 reserves for EP-98 (`keiro.snapshot.decode.failures`) and EP-99
  (`keiro.snapshot.apply.divergence`).
  Date: 2026-07-12

- Decision: implement the shard-path integration against EP-96's delivered
  `ShardDelivery` / `ShardAck` / `runShardedSubscriptionGroupAck` surface and
  retain its existing `ShardedWorkerOptions.retryPolicy` field unchanged.
  Rationale: those artifacts are present and covered by the live 316-example
  baseline, so adding an opportunistic retry-policy field or an alternate ack
  abstraction would duplicate completed work.
  Date: 2026-07-13

- Decision: make `Keiro.Command.commandErrorClass` public and use it as the
  single source for both span `error.type` and dispatch dead-letter
  `error_class`.
  Rationale: the live function already owns every `CommandError` constructor
  and its EP-99 classification. A second mapping in `Keiro.ProcessManager`
  would undermine MasterPlan Integration Point 1's one-class-per-constructor
  contract.
  Date: 2026-07-13

- Decision: exercise Kiroku's exported `subscriptionAckStream` directly in the
  retry-exhaustion integration test instead of hand-rebuilding a Shibuya
  `Adapter`.
  Rationale: this is the public ack-coupled primitive used by both the adapter
  and the shard worker, and it exposes the otherwise-hidden `retryPolicy`
  configuration. The test can therefore prove the exact bounded-delivery and
  checkpoint behavior without duplicating unrelated envelope conversion code.
  Date: 2026-07-13

- Decision: resolve replay sources with one backward `$all` scan per replay
  batch, keyed by event id and exact stored position, rather than deriving an
  exclusive cursor with subtraction.
  Rationale: Kiroku documents `GlobalPosition` as opaque and potentially
  non-dense, and it exposes no exact point read. Starting at the supported
  `GlobalPosition 0` sentinel and advancing with each returned page's final
  cursor is correct under the live contract. One shared scan also avoids an
  independent full-log scan for every dead-letter row.
  Date: 2026-07-13

- Decision: distinguish Kiroku's observed global order from a cross-stream
  domain ordering guarantee in the process-manager and router contracts.
  Rationale: an unsharded subscription is serial and retries in place, while
  sharded members may advance independently. In both cases, independent source
  streams acquire global positions according to append timing, not a business
  prerequisite, so a correlation join must accept either arrival order.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 2 delivered the opt-in rejected-command escape paths without changing
the safe default. Process-manager and router workers share one classifier:
transient failures retry, systemic deterministic failures halt, and only
rejection/ambiguity reaches `RejectedHalt`, `RejectedDeadLetter`, or
`RejectedSkip`. The dead-letter path records target identity and typed error
class before acknowledging, including manager-state rejection at emit index
`-1`; redelivery produces one row. The full suite passes 322 examples.

Milestone 3 makes retry exhaustion explicit and observable without changing
Kiroku's delivery ladder. Process-manager and router Haddocks now distinguish
the adapter's fixed default of five total deliveries from the shard worker's
configurable `retryPolicy`. `kirokuEventBridge` counts terminal source-event
dead letters while preserving an application's existing event handler. The
integration test drives `subscriptionAckStream` through a two-delivery
exhaustion, verifies the structured Kiroku dead-letter and attempt count,
observes the metric, and proves checkpoint advance by receiving the next event.
`cabal build all` and all 323 Keiro examples pass.

Milestone 4 adds a reusable operator replay surface without taking ownership of
Kiroku's rows. The implementation lists dead letters through Kiroku's exported
statement, resolves their sources in one opaque-cursor-safe backward scan, and
records a per-row fresh, duplicate, failed, or missing outcome. Real
process-manager tests prove both important idempotency cases: a fresh replay
appends once and becomes duplicate on the second pass, while an event processed
before replay is duplicate immediately and does not grow either stream. Rows
remain available for later audits or reruns. `cabal build all` and all 325 Keiro
examples pass.

Milestone 5 closes the coordination contract in prose. The process-manager
Haddock now gives a concrete payment/shipment join, distinguishes same-stream
ordering from cross-stream append races and shard concurrency, and requires
order-insensitive correlation state machines. It also names the actual
transaction boundaries: manager event plus timers when an event is appended,
timer-only no-ops separately, and each target dispatch with its projections
separately. Router documentation cross-references the same rule and states that
fan-out is idempotent rather than all-target atomic. `cabal haddock keiro`
renders successfully.


## Context and Orientation

This section is self-contained: it defines every term and names every file so a reader
new to the repository can implement the plan. Paths are relative to the repository root
(`keiro/`), except kiroku paths, which name a dependency repository (see "Locating
dependency sources" below).

### The moving parts

keiro is an event-sourcing framework. Application state lives as immutable events in
PostgreSQL, managed by the *kiroku* event store library. Aggregates are *keiki*
transducers — pure state machines that accept a command in a state and either emit
events (a matching edge) or reject it (no matching edge; keiki's step returns `Nothing`,
which keiro surfaces as the `CommandRejected` constructor of `CommandError`, defined at
`keiro/src/Keiro/Command.hs:118-142`).

A *process manager* (`keiro/src/Keiro/ProcessManager.hs`) is a saga: it subscribes to
events, folds them into its own private event stream (the "manager state", keyed by a
correlation id derived by its `correlate` function), and for each incoming event
dispatches commands to *target* aggregates and schedules timers. A *router*
(`keiro/src/Keiro/Router.hs`) is its stateless sibling: no state stream, but it resolves
a data-dependent set of targets effectfully and dispatches one command to each. Both
share the dispatch result vocabulary `PMCommandResult` (`PMCommandAppended`,
`PMCommandDuplicate`, `PMCommandFailed`, ProcessManager.hs:135-146).

Events reach these workers through a *subscription*: kiroku tails the global event log
and delivers events in order, tracking progress with a per-subscription *checkpoint* (a
row in `kiroku.subscriptions` holding the last-seen global position). keiro has two
delivery paths (masterplan 14, Integration Point 4):

1. The **adapter path**: kiroku's *ack-coupled* bridge
   (`subscriptionAckStream` in `kiroku-store/src/Kiroku/Store/Subscription/Stream.hs`)
   wrapped by the `shibuya-kiroku-adapter` package into a Shibuya `Adapter`. "Ack-coupled"
   means the kiroku worker blocks after delivering each event until the consumer
   finalizes an `AckDecision`; the decision drives kiroku's disposition
   (`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:68-111`):
   `AckOk` checkpoints past the event; `AckRetry delay` redelivers the same event after
   the delay, bounded by the subscription's retry policy; `AckDeadLetter reason` records
   the event in `kiroku.dead_letters` and advances atomically; `AckHalt` cancels the
   subscription **without** advancing the checkpoint, so the halting event replays on
   restart (Kiroku.hs:85-86; `Convert.hs` `toIngestedAck` lines 125-140 shows `AckHalt`
   mapping to the cancel action). `runProcessManagerWorkerWith`
   (ProcessManager.hs:374-411) and `runRouterWorkerWith` (Router.hs:219-250) drain such
   an adapter.

2. The **sharded path**: `keiro/src/Keiro/Subscription/Shard/Worker.hs` runs a leased
   pool of kiroku consumer-group readers. Completed sibling plan
   `docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md`
   converted it to `subscriptionAckStream`. The live surface is
   `runShardedSubscriptionGroupAck` with a per-event `ShardDelivery` and a
   `ShardAck` reply; `ShardedWorkerOptions.retryPolicy` controls the bounded
   Kiroku retry ladder.

### Finding 1 — the rejected-command wedge (MEDIUM)

Trace the wedge through the code. `isTransientCommandError`
(ProcessManager.hs:206-214) classifies `CommandRejected` as non-transient;
`ackForCommandError` (ProcessManager.hs:216-219) therefore maps it to
`AckHalt (HaltFatal …)`; `ackForResults` (ProcessManager.hs:416-433) does the same when
any `PMCommandFailed` in the batch is non-transient (:427-433). The existing test
"worker halts instead of acking when a target dispatch is rejected"
(`keiro/test/Main.hs:1852-1875`) pins this behavior. On the adapter path, `AckHalt`
cancels without advancing the checkpoint, so restart redelivers the same source event.
Now the crucial sequencing: `runProcessManagerOnce` appends the manager's own state
event in its first transaction (ProcessManager.hs:280-304) and only then dispatches
target commands (`finish` → `dispatchCommands`, :306-319). On redelivery the manager
append is detected as a duplicate (`eventAlreadyIn`, :280-282) — but `finish` still
re-runs the dispatch loop, the same command is re-dispatched under the same
deterministic id, rejected again, and the worker halts again: a permanent halt loop that
head-of-line-blocks the subscription (or, in a consumer group, the whole bucket).
Meanwhile the manager's state stream already recorded the reaction, so the saga's
durable history asserts a dispatch that never applied. The only witness of the
divergence is the `keiro.dispatch.failed` counter
(`recordDispatchFailed`, ProcessManager.hs:403,406,426; counter name at
`keiro/src/Keiro/Telemetry.hs:565`).

The router has the same wedge: `ackDecisionFor` (Router.hs:252-264) maps any
non-transient `PMCommandFailed` to `AckHalt`. The documented mitigation — model benign
rejections as *total* transitions in the keiki transducer (an ε-complement self-loop) so
they never surface as failures — exists only in the router's haddock
(Router.hs:192-195); the process-manager module says nothing.

One asymmetry matters for the design: the router has no state stream, so a rejected
router dispatch wedges but does not falsify any history. The process manager can also
fail *before* any dispatch — if the manager's own state command is rejected,
`runProcessManagerOnce` returns an outer `Left CommandRejected` (:297) and nothing was
appended at all; dead-lettering that case is divergence-free.

### Finding 2 — silent retry exhaustion (MEDIUM)

`AckRetry` maps to kiroku's `Retry` result
(`kiroku-store/src/Kiroku/Store/Subscription/Types.hs:153-160`), bounded by the
subscription's `RetryPolicy` (Types.hs:173-179). The default is 5 *total deliveries*
(`defaultRetryPolicy`, Types.hs:187-188). When the bound is reached, kiroku's worker
dead-letters the SOURCE EVENT and advances the checkpoint past it — see the `deliver`
loop in `kiroku-store/src/Kiroku/Store/Subscription/Worker.hs` (around lines 702-722):
`Retry … | attempt >= maxAttempts -> writeDeadLetter … >> go driving (i + 1)`. The
write is atomic with the checkpoint advance
(`insertDeadLetterAndCheckpointStmt`, `kiroku-store/src/Kiroku/Store/SQL.hs:1302-1323`).
So a database outage that outlasts the ladder (with the keiro default
`transientRetryDelay = RetryDelay 5` seconds, ProcessManager.hs:182-188, that is roughly
20 seconds of outage) permanently drops process-manager/router *inputs* into
`kiroku.dead_letters` and processing continues without them. Meanwhile keiro's docs
claim, without any bound: "transient store failures retry" (ProcessManager.hs:22) and
"transient store failures finalize 'AckRetry'" (ProcessManager.hs:350-353).

What exists to build on: the dead-letter table schema is
`kiroku-store-migrations/migrations/0002-add-subscription-dead-letters.sql` —
`kiroku.dead_letters(dead_letter_id, subscription_name, consumer_group_member,
global_position, event_id → FK kiroku.events, reason JSONB, reason_summary,
attempt_count, created_at)`, unique on
`(subscription_name, consumer_group_member, global_position, event_id)`. kiroku exports
a read statement, `readDeadLettersStmt :: Statement (Text, Int32) (Vector
DeadLetterRecord)` (newest first; `kiroku-store/src/Kiroku/Store/SQL.hs:1325-1355`;
`Kiroku.Store.SQL` is an exposed module per `kiroku-store.cabal:47`), but no higher-level
enumerate/redeliver API — the replay path is keiro's to build (Milestone 4). For
observing the transition: `writeDeadLetter` emits `KirokuEventSubscriptionDeadLettered`
through the store-wide event hook (`eventHandler :: Maybe (KirokuEvent -> IO ())` on
kiroku's `ConnectionSettings`, `kiroku-store/src/Kiroku/Store/Connection.hs:97,147`);
`kiroku-metrics` and `kiroku-otel` already consume it (see Surprises & Discoveries). The
ack bridge itself gives the *handler* no exhaustion signal beyond the zero-based
redelivery count on the envelope (`Envelope.attempt`, set from `AckItem.ackAttempt`,
`Convert.hs:122-128`) — the handler is never told "this was the last attempt", so the
store-level hook is the observation surface.

Per-path behavior today: the adapter path has the bounded ladder above, with the bound
frozen at 5 (see Surprises & Discoveries — `KirokuAdapterConfig` does not expose
`retryPolicy`). The sharded path now uses the same Kiroku ack bridge: its
`retryPolicy` is configurable through `ShardedWorkerOptions`, synchronous handler
exceptions become `ShardAckRetry`, and retry exhaustion lands in
`kiroku.dead_letters`. Milestone 3 documents and tests this delivered posture.

### Finding 3 — cross-stream correlation ordering (LOW, document only)

kiroku partitions a category subscription across consumer-group members by a stable hash
of the *originating stream id* (`keiro/src/Keiro/Subscription/Shard.hs:3-5`; also
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs:37-39`). Events from one stream
always arrive in order on one member; events from *different* streams carry no relative
ordering guarantee once sharding or redelivery is in play. A process manager whose
`correlate` joins events from different streams (e.g. an order saga correlating a
`payment-…` stream event and a `shipment-…` stream event by order id) must therefore be
written to tolerate either arrival order. This is a documentation task
(Milestone 5) — the guarantee cannot be strengthened without cross-stream sequencing,
which kiroku deliberately does not provide.

### Relationship to sibling plans

`docs/plans/99-silent-edge-validation-and-divergence-witnesses-on-the-command-path.md`
(EP-99, complete) split `CommandRejected` from `CommandAmbiguous` with distinct
`commandErrorClass` values (masterplan 14, Integration Point 1; the classifier is at
`keiro/src/Keiro/Command.hs:570-578`). This plan stores the error class as a plain
`TEXT` column, so EP-99's taxonomy flows into dead-letter rows with zero schema change.
EP-96 is also complete and owns the shard path's ack surface described above.

### Locating dependency sources

kiroku and shibuya sources are found via mori: run `mori registry show shinzui/kiroku
--full` (and `shinzui/shibuya`) to get the local checkout paths. During authoring the
kiroku repository was at `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`; the
`shibuya-kiroku-adapter` package lives inside that repository. Never search `/nix/store`.
Line numbers cited in this plan are as of commit `bc987f4` in this repository and may
drift; the function names are the stable anchors.

### Build, test, and database provisioning

Everything runs from the repository root, `/Users/shinzui/Keikaku/bokuno/keiro`. Build
with `cabal build all`; the main suite is `cabal test keiro-test`, and the migration
integrity suite is `cabal test keiro-migrations-test` (both appear in the `Justfile`
recipes `haskell-test` and `verify`). The test suite provisions its own PostgreSQL: the
`keiro-test-support` package (`keiro-test-support/src/Keiro/Test/Postgres.hs`) starts a
cached ephemeral server, migrates a template database once (kiroku migrations then keiro
migrations), and clones a fresh database per example (`withMigratedSuite` — see
`keiro/test/Main.hs:317`). No external database or environment variables are needed to
run the tests. `withFreshStoreWith` (Postgres.hs:115-122) lets a test customize kiroku
`ConnectionSettings` before the store opens — Milestone 3 uses it to install an
`eventHandler`.

Migrations are authored with the project CLI (per `keiro-migrations/README.md`):

```bash
cabal run keiro-migrate -- new \
  --manifest keiro-migrations/migrations/manifest \
  --description "keiro dead letters"
cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
```

The CLI picked `0018.sql` in the live tree, appended it to the ordered manifest,
and creates the SQL file under `keiro-migrations/migrations/`. Never edit a shipped
migration. Framework tables are created in the `keiro` schema with a `keiro_` name
prefix and fully qualified DDL — copy the style of
`keiro-migrations/migrations/0009-keiro-subscription-shards.sql`.


## Plan of Work

The work is five milestones. Milestones 1-2 deliver finding 1 (the dead-letter policy),
milestone 3 delivers finding 2's honesty and visibility, milestone 4 delivers finding
2's replay path, and milestone 5 delivers finding 3's documentation. Each is
independently verifiable; 2 depends on 1, 4 is independent of 1-2, and 3 and 5 are
documentation-plus-glue that can interleave.

### Milestone 1 — the `keiro_dead_letters` table and its typed API

Scope: durable storage for rejected-dispatch records. At the end, a new migration
creates `keiro.keiro_dead_letters`, and a new module pair
`keiro/src/Keiro/DeadLetter.hs` / `keiro/src/Keiro/DeadLetter/Schema.hs` exposes a typed
insert and list. Nothing uses it yet.

Author the migration with the CLI as shown above. The DDL (adapt the header comment
style from migration 0009):

```sql
CREATE TABLE IF NOT EXISTS keiro.keiro_dead_letters (
    dead_letter_id          BIGSERIAL    PRIMARY KEY,
    dispatcher_kind         TEXT         NOT NULL,  -- 'process-manager' | 'router'
    dispatcher_name         TEXT         NOT NULL,  -- ProcessManager.name / Router.name
    correlation_id          TEXT         NOT NULL,  -- correlate/key output for the source event
    source_event_id         UUID         NOT NULL,  -- kiroku event id of the source event
    source_global_position  BIGINT       NOT NULL,
    emit_index              INT          NOT NULL,  -- dispatch position; -1 = manager-state append
    target_stream_name      TEXT         NOT NULL,  -- resolved target (or manager) stream
    error_class             TEXT         NOT NULL,  -- commandErrorClass rendering (EP-99-ready)
    error_detail            TEXT         NOT NULL,  -- Show rendering of the CommandError, truncated
    attempt_count           INT          NOT NULL,  -- deliveries observed when dead-lettered (>= 1)
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (dispatcher_name, source_event_id, emit_index)
);

CREATE INDEX IF NOT EXISTS ix_keiro_dead_letters_dispatcher_created_at
    ON keiro.keiro_dead_letters (dispatcher_name, created_at);
```

The unique key makes the insert idempotent under redelivery (`ON CONFLICT … DO NOTHING`
in the insert statement): a crash between the dead-letter write and the ack finalization
redelivers the source event, the rejection recurs, and the second insert is a no-op.
There is deliberately no foreign key into `kiroku.events` (Decision Log). Run
`cabal test keiro-migrations-test` and follow any integrity-gate failures it reports
(manifest/checksum/expected-schema checks); consult `keiro-migrations/README.md` for the
regeneration commands it names.

`Keiro.DeadLetter.Schema` holds the hasql statements, in the exact style of
`keiro/src/Keiro/Subscription/Shard/Schema.hs` (fully qualified `keiro.keiro_dead_letters`
in SQL, `contrazip` encoders, `Hasql.Transaction`-flavoured so callers compose).
`Keiro.DeadLetter` is the typed surface:

```haskell
data DispatcherKind = DispatcherProcessManager | DispatcherRouter

data DispatchDeadLetter = DispatchDeadLetter
    { dispatcherKind :: !DispatcherKind
    , dispatcherName :: !Text
    , correlationId :: !Text
    , sourceEventId :: !EventId
    , sourceGlobalPosition :: !GlobalPosition
    , emitIndex :: !Int
    , targetStreamName :: !StreamName
    , errorClass :: !Text
    , errorDetail :: !Text
    , attemptCount :: !Int
    }

recordDispatchDeadLetter :: (Store :> es) => DispatchDeadLetter -> Eff es ()
listDispatchDeadLetters  :: (Store :> es) => Text -> Eff es [DispatchDeadLetterRecord]
```

(`DispatchDeadLetterRecord` adds `deadLetterId` and `createdAt`.) `errorDetail` is
`Text.take 1024 (Text.pack (show err))` — the same truncation instinct as the span
status at Command.hs:565. Acceptance: a new test group in `keiro/test/Main.hs` inserts
the same record twice and lists exactly one row.

### Milestone 2 — the rejected-command policy on both workers

Scope: the policy type, the wiring in both workers, the metric, the tests, and the
divergence documentation. At the end, a process manager configured with
`RejectedDeadLetter` survives a rejected dispatch: the row is written, the source event
acks `AckOk`, and the next event processes; the default behavior is byte-for-byte
today's halt.

First the data plumbing. Change `PMCommandFailed !CommandError` to
`PMCommandFailed !StoreTypes.StreamName !CommandError` in
`keiro/src/Keiro/ProcessManager.hs:142-146` and update the two construction sites
(ProcessManager.hs:341, Router.hs:172 — both already have `targetStreamName` in scope)
and every pattern match (`ackForResults`'s failure comprehension at :424, router's at
:255, `headDeterministic` callers, and the test suite). This is the Decision-Log-recorded
breaking change.

Then the policy. In `keiro/src/Keiro/ProcessManager.hs`, next to `PoisonPolicy`:

```haskell
-- | What a worker does when a dispatched command is rejected by the target
-- machine (a non-transient, rejection-class 'CommandError').
data RejectedCommandPolicy
    = -- | Halt the subscription without acking (current behavior; the event
      --   replays on restart). Safe default: loud and lossless.
      RejectedHalt
    | -- | Persist a 'DispatchDeadLetter' row and ack the source event so the
      --   subscription proceeds. See the module notes on saga-history divergence.
      RejectedDeadLetter
    | -- | Ack the source event recording only the metric. Choose this only when
      --   the rejection is truly informationless.
      RejectedSkip
```

Add `rejectedCommandPolicy :: !RejectedCommandPolicy` to `WorkerOptions`
(ProcessManager.hs:175-180), defaulting to `RejectedHalt` in `defaultWorkerOptions`.
Define the shared predicate `isRejectionClass :: CommandError -> Bool` (today: matches
`CommandRejected` only; haddock notes that EP-99's rejection/ambiguity constructors join
it) so the policy scope decision lives in exactly one function.

Wire the process-manager worker. The decision point is `handleIngested`
(ProcessManager.hs:395-411) and `ackForResults` (:416-433). Restructure so the ack
computation has what the dead-letter write needs: pass the source `RecordedEvent`, the
correlation id (computed once from `correlate`/`input`), the envelope's attempt count
(`env ^. #attempt`, zero-based; store `attempt + 1`, or 1 when absent), and the worker
options into a new effectful `decideForFailures` that: partitions failures into
transient / rejection-class / other non-transient; on any other-non-transient failure
returns `AckHalt` (policy does not apply); on any transient failure returns `AckRetry`
(rejection-class rows are NOT written yet — the retry will re-dispatch and the rejection
will recur, keeping the write adjacent to the terminal decision); otherwise, all
failures are rejection-class, and the policy decides: `RejectedHalt` → today's
`AckHalt`; `RejectedDeadLetter` → `recordDispatchDeadLetter` for each rejected dispatch
(emit index = position in `commandResults`), bump the new counter, return `AckOk`;
`RejectedSkip` → bump the counter, return `AckOk`. The manager-state rejection (the
outer `Right (Left err)` at :405-407) goes through the same function with emit index
`-1` and the manager's own stream name — under `RejectedDeadLetter`/`RejectedSkip` it
acks and proceeds; the haddock notes this case is divergence-free because nothing was
appended. Export `decideForFailures` — it is the classification EP-96's shard-path ack
surface will reuse (Milestone 3 states the expectation).

Wire the router identically in `runRouterWorkerWith`'s `ackDecisionFor`
(Router.hs:252-264), with `dispatcherKind = DispatcherRouter` and `correlationId` from
`key input`. The router worker's constraint set gains `Store :> es` uses it already.

Telemetry: add `keiroDispatchDeadletteredName = "keiro.dispatch.deadlettered"` and
`recordDispatchDeadLettered` to `keiro/src/Keiro/Telemetry.hs`, following the
`keiro.dispatch.failed` pattern (:565, :785-790). `keiro.dispatch.failed` keeps counting
every failure as today; the new counter counts only policy-dead-lettered/skipped ones.

Documentation: extend the `Keiro.ProcessManager` module haddock (the worker paragraph at
:20-23 and `runProcessManagerWorker`'s at :346-353) with the policy semantics and this
divergence contract, in approximately these words: "Under `RejectedDeadLetter`, a
dead-lettered dispatch means the manager's state stream has recorded a reaction whose
command never applied to the target. keiro cannot append a correction to the manager's
stream (a foreign event would fail the manager's own transducer replay). If the saga's
history must reflect the failure, model a `DispatchFailed`-style command in the manager's
transducer and drive it from the dead-letter table (`Keiro.DeadLetter.
listDispatchDeadLetters`) — by an operator runbook or automation. Otherwise treat the
dead-letter row itself as the durable witness." Also port the router's total-transition
guidance (Router.hs:192-195) into the PM haddock — the modeling fix remains preferable
to any policy.

Tests, in `keiro/test/Main.hs` next to the existing worker group (the harness pieces —
`inMemoryAdapter` at :8599-8616, `rejectingEventStream`, `counterProcessManager` — all
exist): (a) end-to-end dead-letter: worker with `rejectedCommandPolicy =
RejectedDeadLetter` over two messages, first rejected, second normal; assert decisions
`[AckOk, AckOk]`, exactly one `keiro.keiro_dead_letters` row with `error_class =
"command_rejected"`, the correct dispatcher/correlation/source columns, and the second
event's target append present — no halt loop; (b) the existing halt test at :1852 still
passes untouched (default preserved); (c) skip: no row, `AckOk`, counter incremented
(assert via the in-memory metric exporter exactly as the test at :1877-1901 does);
(d) manager-state rejection under `RejectedDeadLetter`: row with `emit_index = -1`,
`AckOk`; (e) router dead-letter path mirroring (a); (f) redelivery idempotency: run the
rejected message through the worker twice, still exactly one row.

Acceptance: `cabal test keiro-test` green with the new tests listed in the output.

### Milestone 3 — retry exhaustion made honest and visible

Scope: documentation corrections, the observability bridge, the per-path posture
statement, and the exhaustion visibility test. No behavior change to the ladder itself.

Documentation. In `keiro/src/Keiro/ProcessManager.hs`, replace the unbounded claims
(module head :20-23; worker haddock :346-353) with the true contract, in approximately
these words: "Transient store failures finalize `AckRetry` and are redelivered, bounded
by the kiroku subscription's `RetryPolicy` (`retryMaxAttempts`, default 5 total
deliveries — `Kiroku.Store.Subscription.Types.defaultRetryPolicy`). When the bound is
exhausted, kiroku records the SOURCE EVENT in `kiroku.dead_letters` with reason
`max_attempts_exceeded` and atomically advances the checkpoint past it: the manager
never sees that event again unless an operator replays it
(`Keiro.DeadLetter.Replay`). On the shibuya-kiroku adapter path the bound is currently
not configurable (`KirokuAdapterConfig` does not expose `retryPolicy`); observe
exhaustion via kiroku's `eventHandler` hook — see `Keiro.Telemetry.kirokuEventBridge`."
Mirror the correction in `Keiro.Router`'s worker haddock (:183-200). Record the missing
adapter knob as an upstream note in this plan's Surprises section (done) and in the
haddock.

The bridge. Add to `keiro/src/Keiro/Telemetry.hs`:

```haskell
-- | Feed kiroku store events into keiro metrics. Install as (or inside) the
-- 'eventHandler' on kiroku's ConnectionSettings at store construction.
kirokuEventBridge :: Maybe KeiroMetrics -> (KirokuEvent -> IO ()) -> KirokuEvent -> IO ()
```

It increments the new `keiro.subscription.deadlettered` counter on
`KirokuEventSubscriptionDeadLettered` (import from `Kiroku.Store.Observability`) and
delegates every event to the wrapped handler (so applications keep their existing
logging/kiroku-metrics wiring; pass `const (pure ())` when none). The haddock states
that this event is the only exhaustion signal — the ack bridge tells the handler only
the redelivery count (`Envelope.attempt`), never "this was the final attempt" — and
gives the operator depth query for dashboards that want a gauge:
`SELECT count(*) FROM kiroku.dead_letters WHERE subscription_name = $1` (a keiro-side
polling gauge was considered and rejected; the counter plus the query is the honest v1).

Per-path posture (masterplan 14, Integration Point 4 — state it in the
`Keiro.ProcessManager` haddock and here): on the **adapter path**, everything above
holds today. On the **sharded path**, completed EP-96
(`docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md`)
delivers the same bounded Kiroku ladder through `subscriptionAckStream`.
`runShardedSubscriptionGroupAck` maps each handler's `ShardAck` to a Kiroku
`SubscriptionResult`, and `ShardedWorkerOptions.retryPolicy` is forwarded into the
subscription configuration. Handlers that dispatch commands can therefore classify
outcomes with Milestone 2's exported `decideForFailures` / `isRejectionClass` and map
the decision to the existing `ShardAck` reply without adding another worker surface.

The test ("force N failures through the ack path"). kiroku's retry ladder is
configurable per subscription — its own test sets
`retryPolicy = RetryPolicy{retryMaxAttempts = 3}`
(`kiroku-store/test/Test/SubscriptionRetryDeadLetter.hs:149`). The adapter hides the
knob. The delivered test exercises the exported common primitive directly: construct a
`SubscriptionConfig` with `retryMaxAttempts = 2`, open
`subscriptionAckStream store subConfig bufferSize`, and answer each `AckItem` reply
with `Retry (RetryDelay 0)` for the first event and `Stop` after accepting the second.
This is the same stream used by both `kirokuAdapter` and EP-96's shard reader, without
duplicating Shibuya envelope conversion (Decision Log). Use `withFreshStoreWith` to
install `eventHandler = Just (kirokuEventBridge metrics …)` on the store. Append two
events to a watched stream. Assert: the first event lands in `kiroku.dead_letters` with
reason kind `max_attempts_exceeded` and `attempt_count = 2` (read it with kiroku's
exported `readDeadLettersStmt` through a transaction); the second event was delivered
and acked (checkpoint advanced — the subscription did not stall); the
`keiro.subscription.deadlettered` counter reads 1 via the in-memory metric exporter.
`RetryDelay 0` keeps the test fast (kiroku clamps the delay at 0 microseconds).

Acceptance: the corrected haddocks render (`cabal build all` passes with `-haddock` as
configured), and the new test passes in `cabal test keiro-test`.

### Milestone 4 — replaying kiroku dead letters

Scope: the operator replay path for finding 2(b). At the end,
`keiro/src/Keiro/DeadLetter/Replay.hs` exports:

```haskell
data ReplayOutcome = ReplayOutcome
    { replayGlobalPosition :: !GlobalPosition
    , replayEventId :: !EventId
    , replayResult :: !ReplayResult
    }

data ReplayResult
    = ReplayedFresh          -- handler ran; new appends occurred
    | ReplayedDuplicate      -- handler ran; every write collapsed to a duplicate
    | ReplayFailed !Text     -- handler returned an error; row left for another pass
    | ReplaySourceMissing    -- no event at the recorded position (see haddock)

listSubscriptionDeadLetters ::
    (Store :> es) => SubscriptionName -> Int32 -> Eff es (Vector DeadLetterRecord)

replaySubscriptionDeadLetters ::
    (Store :> es, …) =>
    SubscriptionName -> Int32 ->
    (RecordedEvent -> Eff es (Either Text ReplayResult)) ->
    Eff es [ReplayOutcome]
```

`listSubscriptionDeadLetters` runs kiroku's exported `readDeadLettersStmt` through
`Kiroku.Store.Transaction.runTransaction` (the same pattern
`Keiro.Subscription.Shard.Schema` uses for its own statements). The delivered
`replaySubscriptionDeadLetters` performs one backward `$all` scan for the complete
batch. It starts at Kiroku's supported `GlobalPosition 0` latest-event sentinel,
advances each page with the final position Kiroku returned, and matches both
`deadLetterEventId` and `deadLetterGlobalPosition`. It never subtracts from or otherwise
derives a cursor: the live Kiroku contract makes positions opaque and potentially
non-dense. A row whose source is absent or mismatched becomes `ReplaySourceMissing`.
It then hands each found event to the caller's handler — for a process manager that is
`\ev -> case decode ev of Just (rec,
input) -> fmap classify (runProcessManagerOnce opts pm rec input); …`, and the haddock
shows exactly this recipe, classifying a result whose `managerResult` and every
`commandResults` element are duplicates as `ReplayedDuplicate`.

The safety argument, stated in the module haddock so operators can trust re-running the
tool: every process-manager and router write id is the same v5 derivation from
`(name, correlation, source event id, emit index)` (ProcessManager.hs:229-243) whether
the event arrives by live delivery or by replay; `eventAlreadyIn` pre-checks each id and
the store's `DuplicateEvent` rejection is folded into a benign duplicate (:292-296,
:339-340). Therefore replaying an event whose writes already happened — including
"the target meanwhile processed it" and "someone already ran replay" — appends nothing
and is safe by construction. Rows are not deleted or marked (Decision Log): kiroku owns
that table, and idempotence makes bookkeeping unnecessary for correctness.

Tests: (a) idempotent replay — dead-letter a source event (drive the handler to
`AckDeadLetter` through the Milestone 3 harness, the cheapest route to a row), process
the same event directly via `runProcessManagerOnce` (simulating the meanwhile-processed
target), then `replaySubscriptionDeadLetters` with the PM recipe: outcome is
`ReplayedDuplicate`, and stream contents are unchanged; (b) fresh replay — same setup
but skip the direct processing: outcome `ReplayedFresh`, the manager and target streams
now contain the reaction; a second replay pass returns `ReplayedDuplicate`.

Acceptance: both tests green; the haddock recipe compiles as a doctest-style example or
is exercised verbatim by test (a).

### Milestone 5 — document the cross-stream correlation ordering footgun

Scope: prose only, in the `Keiro.ProcessManager` module haddock (the natural home; the
router's `key` gets one cross-reference sentence). Add a "Correlation and ordering"
section stating: events of one stream reach a process manager in stream order (kiroku
buckets by a stable hash of the originating stream id — cite
`Keiro.Subscription.Shard`'s header), but events of *different* streams that correlate
to the same manager instance have no relative ordering guarantee. Include a worked
example in approximately this shape: an order saga correlates `payment-ORD1`'s
`PaymentCaptured` and `shipment-ORD1`'s `ShipmentAllocated` by order id; under
consumer-group sharding the two streams may land on different members and a retry on
one member does not stop the other member from advancing. An unsharded subscription
processes its observed global order serially, but that order reflects append timing, not
a domain sequence. The manager's transducer must therefore accept both
`PaymentCaptured → ShipmentAllocated` and the reverse, e.g. by modeling "waiting for
the other half" states rather than assuming one arrival order. State the rule of thumb:
`correlate` may join streams freely, but every join must be order-insensitive, and a
manager that needs a strict sequence must get it from its *own* state machine
(ignore-and-timer-retry, or reject into the Milestone 2 dead-letter path), never from
delivery order. Also state the transaction boundary: manager event + timers commit
together when an event is appended, timer-only no-ops use their own transaction, and
each target dispatch plus inline projections commits separately; the reaction is
idempotent across those boundaries, not globally atomic.

Acceptance: haddock builds; the section is present in `cabal haddock keiro` output (or
simply verified by reading the source header).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless
noted. After each milestone, commit with a Conventional Commits message carrying the
trailer `ExecPlan: docs/plans/100-process-manager-failure-paths-dead-lettering-rejected-commands-and-surfacing-retry-exhaustion.md`.

1. Baseline: `cabal build all && cabal test keiro-test` must be green before starting.

2. Milestone 1:

    ```bash
    cabal run keiro-migrate -- new \
      --manifest keiro-migrations/migrations/manifest \
      --description "keiro dead letters"
    # edit the generated keiro-migrations/migrations/0018.sql with the DDL above
    cabal run keiro-migrate -- check keiro-migrations/migrations/manifest
    cabal test keiro-migrations-test
    # create keiro/src/Keiro/DeadLetter.hs and keiro/src/Keiro/DeadLetter/Schema.hs,
    # add both to keiro/keiro.cabal exposed-modules
    cabal build keiro
    cabal test keiro-test
    ```

    Expected: `check` prints the manifest as valid; both test suites pass, with the new
    insert-twice-list-once example listed, e.g.:

    ```text
    Keiro.DeadLetter
      records a dispatch dead letter idempotently [✔]
    ```

3. Milestone 2: edit `keiro/src/Keiro/ProcessManager.hs`, `keiro/src/Keiro/Router.hs`,
   `keiro/src/Keiro/Telemetry.hs`; extend `keiro/test/Main.hs`. Iterate with:

    ```bash
    cabal build keiro 2>&1 | head -50   # chase the PMCommandFailed arity change
    cabal test keiro-test
    ```

    Expected: compile errors first appear at every `PMCommandFailed` match — that list
    is the complete call-site inventory; when green, the six new examples from
    Milestone 2's test list all appear in the output and the pre-existing halt test
    still passes unmodified.

4. Milestone 3: edit the haddocks, add `kirokuEventBridge` + counter to
   `keiro/src/Keiro/Telemetry.hs`, add the exhaustion test. `cabal test keiro-test`.
   Expected new output line resembling:

    ```text
    retry exhaustion dead-letters the source event, advances, and fires the metric [✔]
    ```

5. Milestone 4: create `keiro/src/Keiro/DeadLetter/Replay.hs`, expose it, add the two
   replay tests. `cabal test keiro-test`.

6. Milestone 5: haddock edits only. `cabal build keiro`.

7. Final gate:

    ```bash
    just verify
    ```

    (Runs process-compose dry-run, `cabal build all`, all test suites, and the website
    build.) Then update this plan's Progress/Outcomes sections and tick the two EP-100
    lines in the masterplan's Progress list.


## Validation and Acceptance

The change is accepted when the following behaviors are observable, not merely compiled:

1. Rejected-command dead-letter path, end to end: a process-manager worker configured
   with `rejectedCommandPolicy = RejectedDeadLetter` receiving a rejected-dispatch event
   followed by a normal event finalizes `[AckOk, AckOk]`; `keiro.keiro_dead_letters`
   contains exactly one row whose `error_class` is `command_rejected` (the EP-99
   taxonomy slot), whose source/dispatcher/correlation/target columns match the event;
   and the second event's effects are present in the target stream. Running the rejected
   event through the worker twice still yields one row. This proves: no halt loop, no
   head-of-line blocking, taxonomy captured, idempotent record.

2. Halt policy preserved: the untouched test at `keiro/test/Main.hs:1852` ("worker halts
   instead of acking when a target dispatch is rejected") passes with
   `defaultWorkerOptions`, proving the default is unchanged.

3. Retry-exhaustion visibility: with a hand-built ack-coupled subscription whose
   `RetryPolicy` is 2, a handler that always retries the first event yields a
   `kiroku.dead_letters` row (`reason` kind `max_attempts_exceeded`, `attempt_count`
   2), delivery of the *second* event (checkpoint advanced — no stall), and
   `keiro.subscription.deadlettered = 1` through the installed `kirokuEventBridge`.

4. Replay idempotency: replaying a dead-lettered source event whose handler effects
   already exist yields `ReplayedDuplicate` and changes no stream; replaying a fresh one
   yields `ReplayedFresh` and a second pass yields `ReplayedDuplicate`.

5. Documentation honesty: `Keiro.ProcessManager`'s haddock no longer claims unbounded
   transient retry; it names the 5-delivery default, the missing adapter knob, the
   dead-letter consequence, the replay entry point, the per-path posture, the
   saga-divergence contract, and the cross-stream ordering caveat with the worked
   example.

Run `cabal test keiro-test` and `cabal test keiro-migrations-test` from the repository
root; every listed example must show `[✔]` and the suites exit 0. `just verify` is the
full gate.


## Idempotence and Recovery

Every step is re-runnable. The migration is guarded by `CREATE TABLE IF NOT EXISTS` and
applied through the `pg-migrate` ledger, which records and skips applied migrations;
`keiro-migrate -- new` refuses to overwrite, so a half-authored migration is finished by
editing the already-generated file, not re-running `new`. Never edit the migration after
it has shipped in a release — schema corrections get a new forward migration
(`keiro-migrations/README.md`). Tests provision throwaway databases per example, so a
failed test run leaves no state; re-run the same command. The dead-letter insert is
idempotent by unique key, so a crash between the row write and the ack finalization is
recovered by redelivery (this is also test 1's double-run assertion). Replay is
idempotent by the deterministic-id argument (Decision Log) and can be re-run after any
partial failure; `ReplayFailed` rows are simply picked up by the next pass. If the
`PMCommandFailed` arity change stalls mid-refactor, the compiler lists every remaining
site; the tree builds again only when all are updated, so there is no silently
half-wired state to recover from.


## Interfaces and Dependencies

Libraries and modules consumed, all already dependencies of the `keiro` package:
`kiroku-store` (`Kiroku.Store.Effect.Store`, `Kiroku.Store.Transaction.runTransaction`,
`Kiroku.Store.Read.readAllBackward`, `Kiroku.Store.SQL.readDeadLettersStmt` +
`DeadLetterRecord`, `Kiroku.Store.Subscription.Types.RetryPolicy`,
`Kiroku.Store.Subscription.Stream.subscriptionAckStream` (tests),
`Kiroku.Store.Observability.KirokuEvent`); `shibuya-core` (`AckDecision`, already
imported); `hasql`/`hasql-transaction` (statements,
following `Keiro.Subscription.Shard.Schema`); `keiro-migrations` (the new migration);
`keiro-test-support` (`withMigratedSuite`, `withFreshStoreWith`).
The registered `shibuya-kiroku-adapter` source was inspected through `mori` to verify
its hidden retry-policy field and use of `subscriptionAckStream`; EP-100 does not add a
package dependency on it.

At the end of each milestone these must exist, with full module paths:

- M1: `Keiro.DeadLetter` exporting `DispatcherKind(..)`, `DispatchDeadLetter(..)`,
  `DispatchDeadLetterRecord(..)`, `recordDispatchDeadLetter :: (Store :> es) =>
  DispatchDeadLetter -> Eff es ()`, `listDispatchDeadLetters :: (Store :> es) => Text ->
  Eff es [DispatchDeadLetterRecord]`; `Keiro.DeadLetter.Schema` with the hasql
  statements; migration `keiro-migrations/migrations/0018.sql` (the number assigned by
  the CLI).
- M2: `Keiro.ProcessManager` exporting `RejectedCommandPolicy(..)`,
  `isRejectionClass :: CommandError -> Bool`, the effectful `decideForFailures` (exact
  signature settled at implementation; it must take the policy, the source event,
  correlation id, attempt count, and the classified failures, and return
  `Eff es AckDecision`), `WorkerOptions` with the new field, and
  `PMCommandFailed !StreamName !CommandError`; `Keiro.Telemetry` exporting
  `recordDispatchDeadLettered` with counter `keiro.dispatch.deadlettered`.
- M3: `Keiro.Telemetry.kirokuEventBridge :: Maybe KeiroMetrics -> (KirokuEvent -> IO ())
  -> KirokuEvent -> IO ()` with counter `keiro.subscription.deadlettered`; corrected
  haddocks in `Keiro.ProcessManager` and `Keiro.Router`.
- M4: `Keiro.DeadLetter.Replay` exporting `ReplayOutcome(..)`, `ReplayResult(..)`,
  `listSubscriptionDeadLetters`, `replaySubscriptionDeadLetters` as specified in
  Milestone 4.
- M5: no code interface; the documented "Correlation and ordering" haddock section.

Integration contracts with sibling plans (masterplan 14): EP-99 consumes the
`error_class` column via `commandErrorClass` — one new class per new constructor, no
reuse of `"command_rejected"` for ambiguity (Integration Point 1), and
`isRejectionClass` is the single classifier for both constructors. EP-96 has delivered
the per-event shard acknowledgement and `ShardedWorkerOptions.retryPolicy` surface;
EP-100 consumes those artifacts without extending them (Integration Point 4).
Telemetry names respect Integration Point 3's reservations.

## Revision Notes

- 2026-07-13: Began implementation, copied the MasterPlan intention into this
  child plan, refreshed the completed EP-96/EP-99 integration context, and
  completed Milestone 1 with CLI-generated migration 0018, typed storage APIs,
  and passing migration plus 317-example Keiro test suites.
- 2026-07-13: Completed Milestone 2. Added shared rejection policy and
  classification, target-aware failure results, process-manager/router
  dead-letter and skip paths, telemetry, saga-divergence documentation, and
  end-to-end coverage; the full Keiro suite passes 322 examples.
- 2026-07-13: Completed Milestone 3. Documented Kiroku's bounded retry and
  per-path configuration posture, added the composable Kiroku event-to-metric
  bridge, and covered two-delivery exhaustion, atomic checkpoint advance, and
  metric emission through `subscriptionAckStream`; all 323 examples pass.
- 2026-07-13: Completed Milestone 4. Added Kiroku dead-letter listing and
  idempotent handler replay with batched opaque-cursor-safe source resolution;
  fresh and already-processed process-manager replay tests bring the passing
  suite to 325 examples.
- 2026-07-13: Completed Milestone 5. Documented same-stream versus cross-stream
  ordering, the payment/shipment correlation example, and manager/router
  transaction boundaries; the Keiro Haddock build succeeds.
