# Workflow & Durable-Execution Prior Art — Survey for keiro

Survey author: research subagent (general-purpose), 2026-05-04. URLs are recorded for traceability; do not rely on them outside research.

> **Corrections note (2026-05-04, reaffirmed 2026-05-08).** Two recommendations in the agent-authored synthesis below were retracted on review against kiroku's and keiki's actual designs. Body passages affected by the first retraction are tagged `[RESCINDED — see corrections note above]` inline (added 2026-05-08) so a reader scanning a single section cannot pick up a recommendation that has already been rejected.
>
> 1. **Marten's high-water-mark is not needed for keiro — this is a settled architectural decision, not an open question.** Kiroku's `docs/DESIGN.md` (§"Core Design Choice: Strategy E", lines 6-21, plus the Design Decisions Log entry "Global ordering strategy") documents *Strategy E*: an atomic `UPDATE … RETURNING` on the `$all` row (`stream_id = 0`) **inside the same transaction that inserts events**. The serialised counter and the row-lock-on-commit together guarantee *gap-free contiguous* `globalPosition`s (1, 2, 3, …) with immediate read-your-own-writes and **no MVCC vulnerability** — explicitly chosen *to avoid* the bigserial-plus-HWM operational tax that Marten's Strategy A pays. Subscribers advance their `last_seen` to any observed `globalPosition` without gap-detection logic; there are no gaps to wait for. The recommendations in §5 (*Eventide / message-db*, the bigserial-gap warning at the end of "Avoid"), §7 (*Marten*, the "Steal: high-water-mark gap detection" item), §"Minimum viable feature set for keiro v1" item 5 (*High-water-mark / gap-aware cursor*), and §"Opinionated synthesis" item 2 (*Adopt Marten's high-water-mark*) were authored without seeing kiroku's design notes; **all four are rescinded.** Authoritative references: `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E" + §"Design Decisions Log" entry "Global ordering strategy"; `docs/masterplans/1-keiro-research-foundation.md` Decision Log entry of 2026-05-04 ("Remove the recommendation to adopt Marten's high-water-mark"); `docs/research/08-subscription-and-process-manager-design.md` §4 ("Gap-free reads — why no watermark is needed"); `docs/research/11-upstream-roadmap.md` §9.1 ("High-water-mark (HWM) for async-subscriber gap detection — Verdict: Not a gap"). **Future readers: do not re-open this question. If a new piece of evidence appears that would re-open it, file it as a Surprises & Discoveries entry on the MasterPlan, not as a recommendation in this survey.**
> 2. **The Chassaing decider is not the keiro ⇄ keiki contract — `Keiki.Decider` is a legacy compatibility facade for the old system that keiro is replacing, and keiro must never rely on it.** The native primitive is `SymTransducer phi rs s ci co` (with the typed register file `RegFile rs`, ε-edges, and a symbolic predicate carrier). The decider/evolve *shape* remains a useful pedagogy for ordinary aggregates and is implementable on top of `SymTransducer`, but adopting the Chassaing facade *as the contract* would amputate the workflow features keiki actually offers (timers and retry counters in registers, silent state advance via ε-edges, future symbolic verification). The recommendations in §"Minimum viable feature set for keiro v1" item 8 (*Decider pattern (keiki)*) and §"Opinionated synthesis" item 4 (*Adopt Chassaing's decider as the keiki API surface*) are rescinded; keiro consumes the native `SymTransducer` directly via EP-1's `Aggregate phi rs s ci co` contract (`docs/research/06-command-cycle-design.md`). Authoritative references: `docs/masterplans/1-keiro-research-foundation.md` Decision Log entry of 2026-05-04 ("Reject `Keiki.Decider` as the keiro ⇄ keiki contract"); `docs/plans/1-command-cycle-design-and-spike.md` §M0 ("First-principles contract derivation"); `docs/research/06-command-cycle-design.md` §"The contract"; `docs/research/02-keiki-decide-loop.md` §"The Decide" (which documents the ε-edge limitation of the `Decider` facade). **Future readers: do not re-open this question. If a new piece of evidence appears that would re-open it, file it as a Surprises & Discoveries entry on the MasterPlan, not as a recommendation in this survey.**
>
> The MasterPlan's Decision Log (`docs/masterplans/1-keiro-research-foundation.md`), EP-1, EP-3, EP-5, and EP-6 reflect both corrections; this survey is preserved verbatim below for traceability, with inline `[RESCINDED — see corrections note above]` markers added 2026-05-08 to the four HWM-related passages so the rescinded recommendations cannot be re-cited by accident.


## 1. Temporal / Cadence

**Core abstraction.** A *workflow* is a deterministic function that orchestrates work. Side effects are quarantined into *activities*, which run outside the workflow's deterministic boundary, with built-in retries. The workflow's full state is a replayable *Event History* persisted in the Temporal server; when a worker starts a workflow task, the SDK replays the history through the workflow function to reconstruct state, then asks the function for the next *Command* (e.g. ScheduleActivity, StartTimer, StartChildWorkflow). Replay drives durability.

**Persistence model.** History events are persisted by the Temporal Service (Cassandra/MySQL/Postgres on the server). Every workflow API generates a Command, which produces one or more Events appended to the workflow's history. A simple workflow with one timer produces ~10 events; signals each generate at least one event plus a workflow task.

**Concurrency / consistency.** Each workflow execution is a single-writer logical actor — the server serializes workflow tasks per execution. Activities run anywhere; their results are recorded into history.

**Workflow / saga story.** Native: child workflows, signals (push to running workflow), queries (synchronous read), updates (signal+blocking-query in one), durable timers, and continue-as-new for long workflows. Sagas are conventional code: catch errors in workflow, run compensation activities.

**Replay / determinism.** Workflow code must be deterministic given identical history. Three sources of nondeterminism violations: random/clock/IO calls outside activities, code-change drift between deploys, and library-internal nondeterminism. Versioning strategies are *patching* (`getVersion`/`patched`) and *Worker Versioning* (versioned task queues). Replay testing is recommended in CI.

**Steal.** (a) The workflow/activity split — a clean line between deterministic orchestration and non-deterministic effect. (b) Continue-as-new as an explicit primitive for unbounded workflows so history doesn't grow without bound (Temporal hard-limits history size).

**Avoid.** (a) Custom server with exotic persistence requirements (frontend/history/matching/worker services) — heavy operational weight that keiro should not replicate on Postgres v1. (b) Coupling determinism to the *exact* AST of user code: in practice, every code change risks a non-determinism error, and patching becomes folklore. Keep the deterministic-replay door open in v2 but don't pay its cost in v1.

**Minimum primitives a Haskell port would need.** Workflow function (deterministic), activity (effectful), durable timer, signal channel, child workflow, history append/replay, command-vs-event distinction, deterministic clock, deterministic UUIDs/random, and a versioning/patch API.

## 2. Restate

**Core abstraction.** *Virtual Objects* are durable functions identified by a key with attached state; *workflows* are one-shot keyed durable functions; *services* are stateless durable functions. Each invocation has a *journal* recording every interaction with the outside world — `ctx.run(...)` (durable side-effect), `ctx.sleep(...)` (durable timer), `ctx.awakeable()` (externally completable promise), state get/set, and outgoing calls.

**Persistence model.** The Restate server is its own log+state engine. New events are appended to a replicated, embedded log called *Bifrost*; processors materialize state into RocksDB and snapshot to object storage.

**Concurrency / consistency.** Per-key serialization on Virtual Objects (one outstanding invocation per key, queued). Across keys, partitions parallelize. State is transactional with the journal entries.

**Workflow / saga story.** Sagas are written as plain code with try/catch + compensating `ctx.run` calls. The journal makes compensations idempotent: on retry, `ctx.run` returns the already-recorded result rather than re-executing.

**Replay / determinism.** Same model as Temporal (re-enter the function, replay journal, skip already-recorded steps), but the SDK can *suspend* the execution between journal entries — so on FaaS the function process can die between awaits without losing work. Awakeables decouple "wait for an external event" from "stay in memory".

**Steal.** (a) The vocabulary of *journaled durable building blocks*: `run`, `sleep`, `awakeable`, state get/set. This is a small, learnable surface that maps well to a Haskell effect (`Effectful.Restate` style). (b) Per-key serialization for keyed entities — exactly what an aggregate needs.

**Avoid.** (a) Running a separate replicated log + state cluster (Bifrost + RocksDB) is the opposite of "Postgres-native". keiro should journal into Postgres. (b) Awakeables are powerful but introduce a global-id namespace and external-completion API; treat as a v2 feature, not v1.

## 3. DBOS

**Core abstraction.** A *workflow* is a function annotated `@workflow`; a *step* is a function annotated `@step` that is checkpointed in Postgres before/after execution. A *transaction step* runs entirely inside a Postgres transaction whose commit also writes the step checkpoint — so the side-effect and the durability marker are in the same `BEGIN/COMMIT`. DBOS runs as a library inside your application, not as a separate server.

**Persistence model.** Pure Postgres. Workflow state, step checkpoints, queues, notifications, and schedules are tables in your database, in the same Postgres cluster as your business data.

**Concurrency / consistency.** Step checkpoints rely on Postgres ACID; transactional steps inherit DB-level isolation. Queues use SKIP LOCKED for concurrent consumption. Recovery is "find unfinished workflows on startup, resume from last checkpoint."

**Workflow / saga story.** Workflows are imperative code with steps; sagas are try/except + compensating steps. Notifications + workflow events let other workflows wait. Queues provide concurrency limits and rate limits.

**Replay / determinism.** DBOS does *not* require deterministic replay in the Temporal sense. On crash, the workflow function is re-invoked from the top, but each `@step` short-circuits if its checkpoint exists, returning the recorded result. This is a much weaker (and simpler) model than full history replay: it forgives ordinary code changes between checkpoints, at the cost of not being able to *deterministically reconstruct* arbitrary intermediate variables.

**Steal.** (a) **The transactional step** — bundle the side effect (a SQL write to your domain table) and the checkpoint into one transaction. This is uniquely powerful with Postgres and should be a first-class keiro primitive. (b) **No separate orchestrator process.** keiro should be a library you import; workers are just OS processes that connect to Postgres. (c) Postgres-native durable queues (already on the roadmap via pgmq-hs).

**Avoid.** (a) The "re-run from the top" model loses some of Temporal's introspectability — there is no canonical event history of *what the workflow did*, only of *what each step returned*. keiro should keep an explicit event log (kiroku) so we get both: domain events for projections + step checkpoints for resumability. (b) Function-name-based workflow identity (DBOS keys checkpoints by function name + invocation id); this couples durability to identifier stability and makes refactoring scary. Prefer explicit workflow IDs and explicit step IDs.

## 4. Inngest

**Core abstraction.** A function is a sequence of named *steps*. Each step (`step.run`, `step.sleep`, `step.waitForEvent`) is memoized: the executor invokes the function over HTTP, the SDK detects which step is requested next, runs it, returns the result, and the executor persists it. On the next invocation, completed steps are short-circuited from state.

**Persistence model.** The Inngest executor is a separate service with its own state store. State per run = the triggering event(s) + step outputs/errors. Each step is one HTTP roundtrip from the executor to the user's function host.

**Concurrency / consistency.** Concurrency limits, rate limits, debouncing, and event-driven fan-out are first-class. Step memoization is the durability model.

**Workflow / saga story.** Sagas are written with `step.run` + `try/catch` + compensating `step.run`. `step.waitForEvent` lets a function block on an external event durably.

**Replay / determinism.** Same memoization-replay model as Temporal/Restate (re-run the function, skip completed steps), but with a critical UX improvement: every step is *named* by the user (`await step.run("charge-card", ...)`) so cross-version stability hinges on the name, not the position-in-history. This is dramatically easier to evolve than Temporal's positional history.

**Steal.** (a) **Named steps** as durability identifiers. keiro's workflow API should require an explicit step key, not derive identity from call position. This single decision avoids 80% of Temporal's nondeterminism pain. (b) **Event-driven function triggers** — workflows can be started by a domain event matching a pattern. This composes naturally with kiroku subscriptions.

**Avoid.** (a) HTTP-per-step is operationally simple but latency-heavy and not a fit for an in-process Haskell library. keiro should keep workflow execution in-process, with the journal in Postgres. (b) Inngest's external service model means application logic and durability live on opposite sides of a network boundary — we get this for free with DBOS-style library design.

## 5. Eventide / message-db

**Core abstraction.** Pure event sourcing on Postgres with a stream-name convention `category-id` and a single `messages` table. Writers append with optimistic concurrency (`expected_version`). Readers consume by stream or by category, paginating on `global_position` (per-category subscriptions are just `get_category_messages(category, position, batch_size, …)`). Handlers are *deciders*: load events into a `Projection` (state), run a `decide(state, command) → [event]`, write results back with the read version.

**Persistence model.** One physical table `message_store.messages` with `global_position bigserial PK`, `position bigint`, `stream_name`, `type`, `data jsonb`, `metadata jsonb`, `id uuid`, `time`. Stream version is per-stream (max position). Category and cardinal-id are derived in SQL. The `write_message` PL/pgSQL function takes an `expected_version` and raises on mismatch.

**Concurrency / consistency.** Optimistic concurrency on stream version, advisory lock per stream during write (`acquire_lock(stream_name)`) to serialize writers, monotonic global_position via `bigserial`. Simple, brutal, correct.

**Workflow / saga story.** No workflows in the box. Sagas/process managers are user code: subscribe to a category, maintain a position, write commands or events back as a result. This is the canonical "event-driven choreography" model.

**Replay / determinism.** N/A — there is no workflow runtime to replay. Aggregates rebuild from events on each command (optionally with snapshots). Projections rebuild by truncating and replaying.

**Steal.** (a) **The whole storage shape.** kiroku already adopts this in spirit. (b) **Categories as a naming convention** (`order-{id}`) plus a SQL function that filters by `category(stream_name)`. This trivially supplies category subscriptions without a separate index strategy. (c) **`global_position` as the universal subscription cursor.**

**Avoid.** (a) PL/pgSQL stored functions for everything. Use the *table shape* and the *expected_version contract* without copying the stored-proc style. (b) `bigserial` global_position has a well-known gap problem under concurrent transactions: position N+1 may commit before position N, so a naive subscriber can skip events. Either use the LSN/`pg_current_snapshot` approach (Marten's "high water mark") or read with a deliberate lag/`xmin`-based fence. **[RESCINDED — see corrections note above. Kiroku does not use `bigserial` for global ordering; Strategy E (atomic `UPDATE` on the `$all` row, claimed inside the same transaction that inserts events) produces gap-free contiguous positions and the bigserial-gap problem does not exist for keiro. Authoritative reference: `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E".]**

## 6. Akka Persistence / Lagom

**Core abstraction.** Persistent entities are typed actors (`EventSourcedBehavior`) with `commandHandler: (State, Command) → Effect[Event]` and `eventHandler: (State, Event) → State` — the decider pattern in actor clothes. Cluster Sharding distributes entities across nodes by id; only one instance per id is alive at a time. Akka Projections consumes the event stream into read models.

**Persistence model.** Pluggable journal + snapshot store (JDBC/Cassandra/R2DBC). Events are persisted before the state machine acknowledges; snapshots are written periodically. Projections track an offset per ProjectionId.

**Concurrency / consistency.** Cluster Sharding gives single-writer-per-entity (an actor mailbox), so writes are serialized without DB-level optimistic concurrency. Recovery on rebalance reloads events for the entity. Projections offer at-least-once *or* exactly-once-with-offset-in-same-transaction (R2DBC).

**Workflow / saga story.** Process managers are themselves persistent entities subscribed to projections.

**Replay / determinism.** Aggregates replay events to rebuild state. No deterministic-replay workflow runtime.

**Steal.** (a) **Exactly-once projection updates by writing offset and read-model rows in the same Postgres transaction.** This is the clean Postgres-native answer to projection idempotency, and it composes with hasql trivially. (b) **Sharded daemon process** model for projection workers — N workers each own a slice of the keyspace with cooperative rebalancing. shibuya can ship a much simpler version: claim slices via advisory locks or a `claims` table.

**Avoid.** (a) **Single-writer-per-entity via cluster membership** is gorgeous in Scala/Akka and a nightmare to operate (split brain, sharding rebalances, gossip). On Postgres, optimistic concurrency on stream version is dramatically simpler and gives the same correctness guarantee. (b) Pluggable-everything (journal, snapshot store, offset store). For v1, pick Postgres and commit.

## 7. EventStoreDB / Marten

**Core abstraction (EventStoreDB).** Append-only log of events organized into streams. The `$all` stream is the global ordering. System projections (`$by_category`, `$by_event_type`) emit *link* events into derived streams. Persistent subscriptions implement competing-consumer with server-side checkpointing; catch-up subscriptions stream from a client-held position.

**Core abstraction (Marten).** EventStoreDB-shaped event sourcing on Postgres, with three projection lifecycles: *Inline* (same transaction as event append, strong consistency), *Async* (Async Daemon, eventual), *Live* (compute on demand). The Async Daemon tracks a "high water mark" — the highest contiguous global event sequence number safe to project from — to handle the bigserial gap problem.

**Persistence model (Marten).** Postgres tables for events + streams + projections + offset checkpoints + dead-letter queue.

**Concurrency / consistency.** Optimistic concurrency on stream version. Inline projections give read-your-writes within the append transaction.

**Workflow / saga story.** Process managers in Marten are async projections that accumulate state and emit commands.

**Replay / determinism.** Projections are rebuildable: blow away the read model, reset the offset, the daemon reprojects. Snapshots are an aggregate-level optimization.

**Steal.** (a) **Three projection lifecycles.** keiro should support inline (same transaction, strongly consistent), async (shibuya-managed, eventually consistent), and live (compute on read). Inline is the killer feature for a Postgres-native engine. (b) **High-water-mark gap detection.** The async daemon tracks both "highest seen position" and "highest contiguous position"; it only feeds events up to the contiguous mark to projections, which solves the bigserial-gap problem cleanly. **[RESCINDED — see corrections note above. Kiroku's Strategy E supersedes HWM at the source: positions are claimed and committed in lockstep, so subscribers never see gaps and have nothing for an HWM to track. Authoritative reference: `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E"; rejected in `docs/research/08-subscription-and-process-manager-design.md` §4.]** (c) **Persistent subscription semantics with server-side checkpoint.**

**Avoid.** (a) Server-side scripted projections (EventStoreDB's JavaScript projections). Operationally fragile and a debugging nightmare. (b) Linking events to derived category streams (`$by_category` link events). It bloats the log; deriving category at read time from `stream_name` is cheaper.

## 8. Reactive Manifesto + Vaughn Vernon DDD

**Core abstraction.** Bonér's *Reactive Manifesto* (2013) defines four properties for distributed systems: Responsive, Resilient, Elastic, Message-Driven. The 2020 update *Reactive Principles* elaborates with concrete principles like "stay responsive", "isolate failures", "delegate failure", "embrace messaging".

Vernon's *Implementing Domain-Driven Design* (Red Book) and *Reactive Messaging Patterns with the Actor Model* formalize **process managers** vs **sagas**: a *saga* is a long-running transaction made up of compensating steps; a *process manager* is a *stateful coordinator* that listens to events and emits commands to drive a business process to completion. Sagas are about distributed transactional rollback; process managers are about workflow orchestration.

**Steal.** (a) **Distinguish saga from process manager in keiki's vocabulary.** A `Saga` is a `decide`/`compensate` decider for a single business transaction. A `ProcessManager` is a `(State, Event) → (State, [Command])` decider that subscribes to one or more categories. (b) **Message-driven boundaries.** Cross-bounded-context communication should be events on kiroku, not direct function calls.

**Avoid.** (a) Hand-waving the saga pattern as "distributed transactions". Two-phase commit is not coming back. We compose local ACID transactions with idempotent compensations. (b) Treating every entity as an actor.

## 9. Haskell prior art

- **`eventful` (jdreaver, archived).** The most-cited Haskell ES library. Provides `Projection`, `CommandHandler`, `ProcessManager`, plus pluggable `EventStore` backends. The abstractions are correct but unmaintained.
- **`eventium` (sidorenko, 2026).** A modernization of `eventful` for GHC 9.10+ with cleaner abstractions. Worth reading as prior-art for ergonomics.
- **`eventsourcing` / `eventsourcing-postgresql` (Tom Feron).** Another CQRS/ES library on Hackage, simpler than eventful, with a Postgres backend.
- **`eventsource-api`.** A lean higher-level API. Smaller surface area but less feature-complete.
- **`hevents` (Arnaud Bailly).** Production-leaning Haskell event-sourcing experiment with good blog posts on the design tradeoffs.
- **Gabriella Gonzalez's `Haskell-Event-Source-Library`.** Tiny, single-file, didactic — useful for understanding minimal types but not production.

**Steal.** (a) `eventful`'s separation of `Projection` (pure fold), `CommandHandler` (pure decider), and `ProcessManager` (subscribe-and-react) is the right type-level cut for keiki. (b) Pluggable backend signatures for testability.

**Avoid.** (a) Using `dependent-sum`/`some` type tricks to model heterogeneous event types in the store. They generate operational complexity around `Typeable`/JSON tagging that's hard to evolve. Prefer a per-aggregate sum type with an explicit `eventTag :: e → Text` and a `Codec` typeclass per aggregate. (b) Free-monad-everywhere designs. Stick to `effectful` semantics.

## Minimum viable feature set for keiro v1

The bar is "production-quality replacement for an in-prod system." The following are non-negotiable for v1.

1. **Append-only event store on Postgres (kiroku).** Already in place.
2. **Optimistic-concurrency append.** Already in place via `ExpectedVersion`.
3. **Stream subscription** (rehydration). Already in place via `readStreamForward`.
4. **Category subscription.** Already in place via `readCategoryForward`.
5. **High-water-mark / gap-aware cursor.** **Missing.** Required for shibuya/keiro to advance subscribers safely under concurrent appenders. Use `pg_current_snapshot` / `pg_current_xact_id` + `pg_snapshot_xmin`, or Marten's running-high-water-mark technique. **[RESCINDED — see corrections note above. Not missing and not required. Kiroku's Strategy E (atomic `UPDATE` on the `$all` row inside the append transaction) produces gap-free contiguous global positions, so a gap-aware cursor has nothing to do. Authoritative reference: `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E"; settled in `docs/masterplans/1-keiro-research-foundation.md` Decision Log entry of 2026-05-04 and `docs/research/08-subscription-and-process-manager-design.md` §4.]**
6. **Inline projections.** **Missing.** When the user appends events, they may also update projection rows in the *same Postgres transaction*. Killer Postgres-native feature.
7. **Async projections (shibuya).** Subscription engine. Track `(subscription_name, last_global_position)`, advance with handler output rows in one transaction. shibuya base + Akka's exactly-once trick.
8. **Decider pattern (keiki).** Already in place (with caveats — the SymTransducer formalism is a superset of `Decider`; the Chassaing-shape facade is exposed). **[CORRECTED — see corrections note above. The keiro ⇄ keiki contract is keiki's native `SymTransducer phi rs s ci co` (consumed via EP-1's `Aggregate phi rs s ci co` record), *not* the `Keiki.Decider` facade. `Keiki.Decider` is a legacy compatibility shim for the old system; keiro must never rely on it. Authoritative reference: `docs/research/06-command-cycle-design.md` §"The contract derivation"; `docs/masterplans/1-keiro-research-foundation.md` Decision Log entry of 2026-05-04 ("Reject `Keiki.Decider` as the keiro ⇄ keiki contract").]**
9. **Idempotent command handlers.** **Missing.** Every command carries a `CommandId` (UUID); handler dedups on stream metadata.
10. **Snapshots (per-aggregate).** **Missing.** Sidecar `snapshots` table; loaders prefer snapshot+tail-events to full replay.
11. **Projection rebuild.** **Missing.** Operator command that truncates a read model, resets its checkpoint to 0, and replays. Must be safe to run on a hot system (shadow table, swap on completion).
12. **Process managers.** **Missing.** Subscribe to a category, maintain durable state per process-manager instance (their own stream in kiroku), emit commands. Pure `(state, event) → (state, [command])` step.
13. **Sagas.** v1 keeps it simple: process manager + explicit compensation events authored by the application.
14. **Durable timers.** **Missing.** A `timers(id, fire_at, payload, status)` table polled by a worker.
15. **Durable queue (pgmq-hs).** Already in place.
16. **Transactional outbox.** **Missing.** External integrations write outbox rows in the same transaction as the domain event.
17. **Inbox / consumer dedup.** **Missing.** When *consuming* from an external source, write `(source, message_id)` to an inbox table inside the handler transaction.
18. **Transactional step.** **Missing.** A keiro-level primitive that runs a Hasql transaction containing both append-to-kiroku and the user's domain SQL. DBOS insight applied surgically.
19. **Observability.** Partial — shibuya already emits OpenTelemetry; kiroku has limited correlation/causation helpers. Need automatic context propagation.
20. **Versioned event schemas.** **Missing.** Per-event-type schema version in metadata; upcasters in keiki run on read.
21. **Test backend.** **Missing.** An in-memory kiroku that satisfies the same interface, used by user tests.

## Stretch features for keiro v2

Defer until v1 is in production.

1. **Full deterministic-replay durable execution.** A workflow runtime where a Haskell function is journaled and replayed step by step. Critical design choice: use Inngest-style **named steps**, not Temporal-style positional history.
2. **Awakeables / external-completion handles.** Durable promises that an external system can resolve by ID.
3. **Child workflows.** Composition primitive for v2 workflows.
4. **Continue-as-new equivalent.** When a workflow's journal grows past a threshold, snapshot its state and rotate its journal.
5. **Versioning / patching API.** Explicit `patch :: PatchId → Workflow Bool` primitive.
6. **Multi-region / global-ordering.** v1 is single-Postgres.
7. **Server-side scripted projections.** Don't build this.
8. **Consumer-group sharding for category subscriptions.** Add when a single subscription handler can't keep up; not before.
9. **Cluster-aware leadership.** v1 can rely on advisory locks per subscription name.
10. **Schema registry.** Useful at scale.
11. **Push-based delivery via Postgres LISTEN/NOTIFY.** Polling is fine for v1.
12. **Encryption at the field level / GDPR crypto-shredding.** Add when a customer demands it.

## Opinionated synthesis

The strongest signal across these systems is that **the Postgres-native, library-not-server design wins at our scale**. DBOS and Marten both demonstrate it; Temporal and Restate are powerful but the ops cost is enormous and most of it is paid to enable deterministic replay.

keiro should:

1. **Adopt message-db's storage shape** verbatim, in spirit (kiroku already does).
2. **Adopt Marten's high-water-mark** to avoid the bigserial-gap pitfall in shibuya. **[RESCINDED — see corrections note above. Kiroku does not use bigserial for global ordering; Strategy E (atomic counter on the `$all` row, claimed inside the append transaction) eliminates the pitfall at the source. Adopting HWM at the keiro/shibuya layer would re-pay the operational tax kiroku declined. Authoritative reference: `kiroku/docs/DESIGN.md` §"Core Design Choice: Strategy E"; rejection settled in `docs/research/11-upstream-roadmap.md` §9.1 ("Verdict: Not a gap").]**
3. **Adopt DBOS's transactional step** as the killer Postgres primitive — exposed via an `Effectful.Kiroku.transaction` combinator that lets users append events + write domain rows + write projection rows atomically.
4. **Adopt Chassaing's decider** as the keiki API surface (decide and evolve, both pure, with explicit initial state). Keiki's SymTransducer is a richer form; the Decider facade is the public API. **[RESCINDED — see corrections note above. `Keiki.Decider` is a legacy compatibility facade for the old system that keiro is replacing — it masks ε-edges, ignores the register file `RegFile rs`, and discards the symbolic predicate carrier `phi`. Keiro consumes the native `SymTransducer phi rs s ci co` directly via EP-1's `Aggregate phi rs s ci co` contract. Authoritative reference: `docs/research/06-command-cycle-design.md`; `docs/masterplans/1-keiro-research-foundation.md` Decision Log entry of 2026-05-04 ("Reject `Keiki.Decider` as the keiro ⇄ keiki contract"); `docs/plans/1-command-cycle-design-and-spike.md` §M0 ("First-principles contract derivation").]**
5. **Defer durable execution** to v2. v1 ships **process managers** that are themselves event-sourced (state rebuilt by replaying their consumed-event log). Covers ~90% of "workflow" use cases without the determinism tax.
6. **Pick named-step durability** for v2 workflows, learning from Inngest's UX win over Temporal.
7. **Reject the "pluggable everything" temptation.** Postgres only, hasql only, effectful only. Discipline now means we ship.

The competitive position of keiro: a Haskell-first, Postgres-native, library-shaped event-sourcing engine with strong inline projections and Marten-grade async projections, plus first-class process managers and an explicit upgrade path to durable execution. Nobody else in the Haskell ecosystem occupies that slot.

## Sources (URLs preserved for traceability)

- Temporal: docs.temporal.io/workflows, /workflow-definition, /encyclopedia/event-history/, /develop/go/versioning
- Continue As New discussion: community.temporal.io/t/continue-as-new-when-reaching-5-000-events-limit/4260
- Replay testing: bitovi.com/blog/replay-testing-to-avoid-non-determinism-in-temporal-workflows
- Restate: docs.restate.dev/concepts/durable_building_blocks, /develop/ts/awakeables, restate.dev/blog/building-a-modern-durable-execution-engine-from-first-principles
- DBOS: dbos.dev/dbos-transact, dbos.dev/blog/why-postgres-durable-execution, docs.dbos.dev/typescript/tutorials/queue-tutorial
- Inngest: inngest.com/docs/learn/how-functions-are-executed, inngest.com/docs/learn/inngest-steps
- Eventide / message-db: eventide-project.org, github.com/message-db/message-db
- Decider — Chassaing: thinkbeforecoding.com/post/2021/12/17/functional-event-sourcing-decider
- Akka: doc.akka.io/libraries/akka-core/current/typed/index-persistence.html, doc.akka.io/libraries/akka-projection/current/r2dbc.html
- EventStoreDB: developers.eventstore.com/clients/grpc/persistent-subscriptions
- Marten: martendb.io/events/projections/async-daemon.html
- Reactive Manifesto: reactivemanifesto.org, reactiveprinciples.org
- Process Managers vs Sagas: infoq.com/news/2017/07/process-managers-event-flows, event-driven.io/en/saga_process_manager_distributed_transactions
- Haskell ES: github.com/jdreaver/eventful, sidorenko.me/blog/2026/04/eventium-event-sourcing-library-for-haskell, hackage.haskell.org/package/eventsourcing, hackage.haskell.org/package/eventsource-api, abailly.github.io/posts/event-source.html, github.com/Gabriella439/Haskell-Event-Source-Library
- Snapshots in ES: kurrent.io/blog/snapshots-in-event-sourcing
- Outbox: microservices.io/patterns/data/transactional-outbox.html, event-driven.io/en/outbox_inbox_patterns_and_delivery_guarantees_explained
- pgmq: tembo.io/blog/introducing-pgmq, github.com/pgmq/pgmq
