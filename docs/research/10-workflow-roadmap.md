# Workflow Engine and Durable Execution Roadmap — keiro

Author: ExecPlan EP-5 (`docs/plans/5-workflow-engine-and-durable-execution-roadmap.md`). Date: 2026-05-06.

This document fixes what "workflow" means in keiro, what ships in v1, what is deferred to v2, and how the v1 substrate evolves into v2 without rewrites. It is the roadmap document the rest of the project — including the upstream roadmap (EP-6, `docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`) — refers to when scoping the workflow surface. The reader is assumed to have read `docs/research/05-workflow-prior-art.md` (the literature survey) and `docs/research/08-subscription-and-process-manager-design.md` (EP-3's process-manager substrate). Where a key fact from those documents matters here it is repeated; the reader who has not seen them should still be able to follow this design.

EP-5 is a design-only plan: there is no spike. The substance is selection, not feasibility — every primitive named here is either implementable on top of the v1 substrate that EP-1 through EP-4 already specify, or is deliberately deferred until v2.


## 1. Problem statement

The user described keiro as "a comprehensive event sourcing and workflow engine framework, possibly supporting durable execution in the future". Two pressures push that intent in different directions:

- *Workflow* is a vague term users will reach for. Without a fixed scope it expands to mean anything — sagas, sagas-with-compensation, named-step durable execution, awakeables, child workflows, retry policies, scheduling. Every system surveyed in `docs/research/05-workflow-prior-art.md` (Temporal, Restate, DBOS, Inngest, Eventide, Akka, EventStoreDB/Marten) draws the line in a different place.
- *Durable execution* in the Temporal/Restate sense is the most powerful workflow primitive available, and also the most expensive to ship correctly. Determinism violations, code-change drift between deploys, history bloat, and library-internal nondeterminism all become production problems the moment the runtime exists. `docs/research/05-workflow-prior-art.md` §1 ("Avoid") is explicit: "Coupling determinism to the *exact* AST of user code: in practice, every code change risks a non-determinism error, and patching becomes folklore".

The roadmap therefore has two jobs. First, draw the v1 line precisely enough that an implementer reading EP-1 through EP-4 plus this document can build keiro v1 without wondering whether some workflow feature is in or out. Second, fix the shape of v2's durable-execution surface ahead of time so the v1 substrate is forward-compatible — the v2 layer adds primitives on top, it does not replace v1's process-manager substrate.

The user-visible behaviour the eventual library will deliver:

- *In v1*, workflow authors compose **process managers** (designed in EP-3, `docs/research/08-subscription-and-process-manager-design.md` §5) plus **durable timers** (this document §3). A "workflow" in v1 is an event-sourced coordinator with timer-driven advancement; sagas with compensation are a special case authored as ordinary process managers.
- *In v2*, workflow authors additionally compose **journaled durable functions with named steps**, **sleeps**, and **external-completion handles** (awakeables). The v2 layer journals into kiroku alongside the v1 process-manager streams; a v1 workflow becomes a v2 workflow by re-expressing its `(state, event) -> (state, [command])` step function as a sequence of `step "..."` calls.

This document fixes which features land in which version and why.

Term definitions (precise — this document is where the vocabulary is fixed):

- *Workflow* — the general, vague term users reach for. In v1 it means "process manager" (§2); in v2 it means a journaled durable function whose execution is checkpointed at named steps (§4).
- *Process manager* — an event-sourced coordinator with a `(state, event) -> (state, [command])` step function. Subscribes to one or more event categories. Maintains its state in its own kiroku stream `pm-<pmName>-<correlationId>`. Defined in EP-3.
- *Saga* — a special case of a process manager whose step function emits compensating commands when downstream commands fail. v1 has no separate saga primitive — sagas are process managers with a `(state, event) -> (state, [Compensate ... | Continue ...])` shape.
- *Durable execution* — execution model where a function can be paused and resumed across crashes, redeployments, and idle gaps by replaying recorded checkpoints. The hallmark of Temporal, Restate, Inngest, DBOS. Deferred to v2.
- *Named step* — a fragment of a durable function uniquely identified by a string label, not by source position. A retry replays only un-checkpointed steps. v2's chosen durability discriminator (§4).
- *Positional history* — the alternative durability discriminator: the position of the step in the function's call sequence. Brittle under code changes (Temporal's well-known nondeterminism pain). v2 explicitly *rejects* this in favour of named steps.
- *Awakeable* — a durable promise resolved by an external system, identified by an opaque id. Useful for human-in-the-loop, third-party callbacks, agentic AI loops. v2 feature.
- *Child workflow* — a workflow spawned by a parent workflow, recorded in the parent's journal so the parent can wait on or cancel it. v2 feature.
- *Continue-as-new* — explicit primitive for unbounded workflows: snapshot state, rotate the journal stream, resume against the rotated stream. v2 feature.
- *Durable timer* — a `(timer_id, fire_at, payload)` row in a database, polled by a worker; on fire, the payload is dispatched (typically as a kiroku append into a process manager's source category). v1 feature (§3).


## 2. v1 minimum-viable feature set

What ships in v1, with one paragraph each. Every entry is either already designed in another EP (cross-linked by file path) or is fixed by this document.

**1. Process managers.** Designed in EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §5). A process manager is an event-sourced coordinator: it subscribes to a kiroku category via `Shibuya.Adapter.Kiroku.kirokuAdapter`, maintains its state in its own kiroku stream `pm-<pmName>-<correlationId>`, and on each event runs `(s, event) -> (s, [PMCommand])` to produce a new state and zero-or-more commands targeted at other aggregates. Multi-stream atomicity for emission rides on `Kiroku.Store.Append.appendMultiStream` (the PM state-advance event and every emitted command's target-stream append commit in one `TxSessions.transaction`). Idempotency on emitted commands uses deterministic v5 UUIDs over `(pmName, correlationId, ev.eventId, emitIndex)` so a crash-and-replay produces the same `commandId` and the second `appendToStream` returns `DuplicateEvent`. This is the v1 substrate for "workflow".

**2. Durable timers.** Specified in §3 of this document. A `keiro_timers(timer_id, fire_at, owner_stream, payload, status, ...)` table polled by a worker; on fire, the worker appends a synthetic `TimerFired { timerId, payload }` event to the owner's process-manager stream (or, for v2, to a workflow's journal stream). Timers are cancellable (the worker checks status before firing). Without this primitive, every timeout-based saga forces the application to integrate an external scheduler, contradicting the "library, not server" thesis.

**3. Transactional outbox / inbox.** Designed in EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §6 — outbox; §7 — inbox). The outbox table `keiro_outbox(id, destination, payload, ...)` is written inside the user's `Hasql.Transaction.Transaction` so the side-effect intent is committed atomically with the projection / event append; a separate drain worker enqueues to a pgmq queue with `SELECT ... FOR UPDATE SKIP LOCKED` and deletes the outbox row in the same transaction. The inbox table `keiro_inbox(source, message_id, seen_at)` is its dedup-on-receive dual. Both are essential to any workflow that calls external systems.

**4. Sagas via process managers + explicit compensation events.** No separate saga primitive ships in v1. A saga *is* a process manager whose step function reacts to failure events with compensating commands — the application authors the compensation events explicitly. Concretely: `OrderPlaced -> [ReserveInventory, ChargeCard]`; on `InventoryReservationFailed`, the PM emits `CancelOrder`; on `CardChargeFailed` after `InventoryReserved`, the PM emits `[ReleaseInventory, CancelOrder]`. The application's event vocabulary carries the compensation; the PM's step function is the policy. Two-phase commit is not coming back; we compose local ACID transactions with idempotent compensations (per `docs/research/05-workflow-prior-art.md` §8).

**5. Inline projections.** Designed in EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §2). Read-model rows are updated in the *same Postgres transaction* as the event append; reads see the new state immediately, no replication lag. The Marten killer-feature, applicable to any workflow that needs strong-consistency views of its own state (e.g., a saga that reads "do I already have an inventory reservation?" between two of its own steps).

**6. Async projections.** Designed in EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §3). At-least-once with user-side idempotency in v1 (a forwarded EP-6 upstream gap blocks exactly-once via transactional checkpoint advance). Workflow status views and external observability dashboards typically live behind async projections rather than inline ones.

**7. Snapshots.** Designed in EP-4 (`docs/research/09-snapshot-strategy.md`). Sidecar `keiro_snapshots` table keyed on `stream_id`, holding the encoded joint state `(s, RegFile rs)` plus `state_codec_version` and `regfile_shape_hash` discriminants. Snapshots are advisory — never load-bearing — so a stale row falls through to full replay rather than blocking a working command path. Long-lived process-manager streams (and v2 workflow journal streams) are the primary beneficiaries: a workflow that runs for weeks must not pay a full-replay cost on every command.

**8. Idempotent commands.** Designed in EP-1 (`docs/research/06-command-cycle-design.md` §9). Every command carries a `CommandId :: UUID`; the handler dedups by writing the id into kiroku's `event_id` column and treating `DuplicateEvent` on `appendToStream` as success. Process managers emit deterministic v5 UUIDs over `(pmName, correlationId, sourceEventId, emitIndex)` so retried emissions collapse to a single append. Workflow authors get idempotency for free as a consequence — every command emitted by a v1 PM (or a v2 step) is at most appended once.


## 3. Durable timers — the one v1 primitive this document owns

Process managers cover saga-style coordination but cannot, by themselves, advance state on the basis of *time elapsing*. A PM whose step function reacts to "no payment confirmation in 5 minutes" needs an event source that produces a `TimerFired` event at the right moment. The v1 primitive is a `keiro_timers` table polled by a worker.

**Schema.** A new Postgres table, owned by keiro (not kiroku):

    CREATE TABLE keiro_timers (
      timer_id     uuid PRIMARY KEY,
      owner_stream text NOT NULL,                 -- e.g., "pm-orderfulfillment-42"
      fire_at      timestamptz NOT NULL,
      payload      jsonb NOT NULL,
      status       text NOT NULL DEFAULT 'pending',  -- pending | fired | cancelled
      created_at   timestamptz NOT NULL DEFAULT now(),
      fired_at     timestamptz
    );
    CREATE INDEX keiro_timers_due
      ON keiro_timers (fire_at)
      WHERE status = 'pending';

The partial index on `status = 'pending'` keeps the polling query cheap as fired/cancelled rows accumulate.

**Write path.** A process manager that wants a timer inserts a row in the same `Hasql.Transaction.Transaction` as its state advance. Concretely: when the PM emits `[ScheduleTimer (timerId, fireAt, payload), ...other commands]`, the multi-stream commit also inserts the `keiro_timers` row, so the timer is durable atomically with the PM state that depends on it. (The PM author wraps this as an ordinary `Hasql.Transaction.Transaction ()` action and threads it through `runCommandWithSql` — the EP-3 outbox path uses the same machinery.)

**Cancel path.** Cancellation is a status flip:

    UPDATE keiro_timers
       SET status = 'cancelled'
     WHERE timer_id = $1
       AND status = 'pending';

The `status = 'pending'` guard makes cancellation idempotent — a double-cancel is a no-op, and a cancel that races a fire either wins (timer never fires) or loses (timer already fired, the PM observes the `TimerFired` event and ignores it via its idempotency contract).

**Fire path.** A worker polls the partial index for due rows:

    SELECT timer_id, owner_stream, payload
      FROM keiro_timers
     WHERE status = 'pending'
       AND fire_at <= now()
     ORDER BY fire_at ASC
     LIMIT $1
     FOR UPDATE SKIP LOCKED;

For each row, the worker appends a synthetic `TimerFired { timerId, payload }` event to `owner_stream` and updates `keiro_timers.status = 'fired'` plus `fired_at = now()` in the *same* `TxSessions.transaction` — the `appendToStream` and the status flip commit together so a crash between them cannot produce duplicate or lost fires. The PM then receives the event through its ordinary subscription and advances state.

**Why owned by keiro, not kiroku.** Timers are a workflow concern, not an event-store concern. Pushing the table into kiroku would force every kiroku user (including those who never write a process manager) to take a position on scheduling. EP-6 may revise this decision if a strong reason emerges — for example, if kiroku ends up wanting timers as a primitive for its own subscription-driven cleanup. Until then the table lives in keiro.

**Why not pgmq with a delayed-visibility timeout.** pgmq's visibility-timeout primitive can simulate scheduled delivery for short windows, but (a) the maximum delay is bounded by the visibility-timeout type, (b) cancellation requires a separate mechanism, and (c) timer durability on pgmq is by message rather than by status, so reasoning about "the timer for this PM correlation" requires a separate index. A first-class table is clearer and not meaningfully more code.

**Concurrency policy on the worker.** `Concurrency = Async n`, `Ordering = Unordered`. `SKIP LOCKED` lets multiple workers claim disjoint rows; per-timer order does not matter (the appended `TimerFired` events carry their original `fire_at` so the PM can resolve out-of-order delivery if needed). A single worker is sufficient for v1; multi-worker is a v1 stretch when timer volume warrants.

**Open question forwarded to EP-6.** The timer-firing worker can either (a) be a stand-alone OS process, or (b) reuse shibuya's supervised-worker substrate. Option (b) would let operators monitor timer-firing alongside the rest of keiro's pipelines using shibuya's existing OpenTelemetry spans and shibuya-metrics gauges; option (a) keeps keiro's runtime footprint minimal. EP-6 picks based on whether shibuya's supervisor is general enough to host a non-adapter-shaped worker without changes.


## 4. v2 durable execution — named steps over a journaled function

The v2 stretch feature — full deterministic-replay durable execution — is deferred until v1 is in production. This section fixes the shape ahead of time so v1's substrate is forward-compatible.

**The decision: named steps, not positional history.** Per `docs/research/05-workflow-prior-art.md` §1 vs §4. Inngest's named-step model (`step.run("charge-card", ...)`) makes durability identifiers explicit so cross-version evolution becomes a compile-time/lint problem instead of a runtime non-determinism nightmare. Temporal's positional model requires every code change between deploys to be guarded by a `getVersion`/`patched` call to avoid corrupting in-flight workflow histories — well-known folklore that v2 keiro will not adopt. With named steps, renaming a step is a deliberate operator action; reordering steps in source has no effect on durability.

**The API shape (preview).**

    -- Keiro.Workflow (v2 preview)
    data WorkflowId
    newtype StepName = StepName Text
    data AwakeableId

    step       :: StepName -> Eff es a -> Workflow es a
    sleep      :: NominalDiffTime -> Workflow es ()
    awakeable  :: Workflow es (AwakeableId, Eff es a)
    runWorkflow :: WorkflowId -> Workflow es a -> Eff es a

`Workflow es a` is an `effectful`-style effect (a labelled wrapper around `Eff es a`) whose handler journals every `step`/`sleep`/`awakeable` interaction into a kiroku stream `wf-<workflowId>` as a `StepRecorded { name, result, timestamp }` event. The journal *is* the workflow's history; there is no parallel "workflow history" table.

**Journaling and replay.** Every `step "name" action`:

1. Looks up `name` in the workflow's journal (loaded into memory at workflow entry).
2. If `name` is already journaled, returns the recorded `result` immediately (no side-effect).
3. Otherwise, runs `action` to produce `a`, encodes it through a `Codec a`, appends `StepRecorded { name = "name", result = encoded a, timestamp = now }` to the journal stream, and returns `a`.

`sleep delta` becomes `step "sleep:<id>" (registerTimer delta)` — the timer table from §3 carries the durable wait. `awakeable` becomes `step "awk:<id>" (registerAwakeable id)` — an `keiro_awakeables(id, status, payload)` table holds the resolution state.

**Re-entry on crash.** On restart, the workflow runtime finds workflows whose journal lacks a `WorkflowCompleted` event. For each unfinished workflow, the runtime re-invokes the workflow function from the top with the journal pre-loaded: every `step` whose name appears in the journal short-circuits to the recorded result; the first un-journaled step re-runs from scratch. This is the DBOS model (`docs/research/05-workflow-prior-art.md` §3), with the named-step durability discriminator borrowed from Inngest (`docs/research/05-workflow-prior-art.md` §4).

**Why kiroku for the journal.** Per the EP-5 plan's Decision Log: uniformity. Workflow journals share the storage substrate with domain events; operators view a workflow's journal alongside the events it consumed by reading two streams from the same store. A separate `journal` table would force a parallel storage mechanism and a parallel observability story.

**Step-result snapshots.** Long-running workflows (millions of steps) face the same hydration cost as long-lived process managers. EP-4's snapshot machinery applies: `Keiro.Workflow` uses an `esSnapshotPolicy` of `Every n` over the journal stream, with the joint state being the workflow's accumulated step results (encoded as a register-file analogue). The snapshot path treats the workflow's `step` map as a `RegFile`-shaped value; EP-4's `regfile_shape_hash` discriminant covers schema evolution of step-result types.

**What this is *not*.** It is not Temporal-style deterministic replay over user code — there is no requirement that the workflow function be deterministic outside `step` calls. Code between steps can be anything (logging, decisions, branching); the journal only constrains the *side-effects* (each `step`'s `action`). This is a much weaker — and simpler — model than Temporal/Cadence; it forgives ordinary code changes between checkpoints, at the cost of not being able to deterministically reconstruct arbitrary intermediate variables (`docs/research/05-workflow-prior-art.md` §3 calls out this trade-off explicitly).


## 5. Substrate continuity — how v1 process managers become v2 workflows

The v1 substrate (event-sourced process managers + durable timers) and the v2 substrate (journaled durable functions with named steps) sit on the same kiroku event log and use the same EP-1 command cycle. A v1 process manager *is* a v2 workflow with one explicit step; conversely, a v2 workflow is a process manager whose step function happens to be journaled call-by-call.

**The continuity argument.** Per the parent MasterPlan's Decision Log (2026-05-04): keiro's contract with keiki is the native `SymTransducer phi rs s ci co`, not the `Decider` facade. A v1 process manager is a `SymTransducer phi rs sP cP cmd` whose:

- Input alphabet `cP` — the source-aggregate's events the PM consumes (often via `Keiki.Composition.compose`/`alternative` to merge multiple categories).
- Output alphabet `cmd` — the targeted aggregates' commands the PM emits.
- Control vertex `sP` — the PM's own state machine (e.g., `OrderFulfillment = AwaitingInventory | AwaitingPayment | Fulfilled | Cancelled`).
- Register file `RegFile rs` — typed slots carrying timer fire-times, retry counters, correlation ids, and (in v2) child-workflow handles.

A v2 durable workflow sits on top: a workflow function `Workflow es a` is sugar over a journaled execution of `step` calls keyed by named steps, where each step's result becomes a register-file-shaped slot in the workflow's accumulated state, and replay short-circuits on already-recorded slot values. The journal stream `wf-<workflowId>` is the v2 analogue of the v1 PM state stream `pm-<pmName>-<correlationId>`; the `StepRecorded` event is the v2 analogue of the v1 `PMStateAdvanced` event.

**Concretely.** A v1 PM that runs

    pmStep :: OrderState -> OrderEvent -> (OrderState, [PMCommand])
    pmStep AwaitingInventory (InventoryReserved sku qty) =
      (AwaitingPayment, [PMCommand chargeCardEventStream orderId (ChargeCard ...)])

becomes a v2 workflow that runs

    orderFulfillment :: OrderId -> Workflow es ()
    orderFulfillment orderId = do
      _ <- step (StepName "reserve-inventory") (runCommand inventoryEventStream ... (ReserveInventory ...))
      _ <- step (StepName "charge-card")       (runCommand chargeCardEventStream ... (ChargeCard ...))
      ...

Both are correct expressions of "fulfil this order"; the v1 form is reactive (driven by source events), the v2 form is imperative (driven by the workflow function's control flow). The v2 form's journal carries the same information the v1 form's PM stream carries — the sequence of steps observed and their results. An operator inspecting a stuck workflow reads `wf-<id>` rather than `pm-orderfulfillment-<id>`; the on-disk data shape is the same shape (a kiroku stream of typed events, each carrying its `StepRecorded` or `PMStateAdvanced` payload).

**The migration story.** A v1 deployment that wants to upgrade an individual workflow to v2 keeps the existing `pm-orderfulfillment-<id>` streams in place (they remain valid history), introduces a v2 `Workflow` function that resumes from a quiescent v1 state by reading the v1 stream into its initial step-result map, and routes new instances through `runWorkflow` rather than the v1 PM dispatcher. EP-5 does not specify the migration in detail — that is a v2 implementation concern — but the substrate continuity guarantees the migration is mechanical, not a rewrite.


## 6. v2 stretch feature set

Deferred until v1 is in production. Each entry one paragraph: what it is, why deferred. None of these block v1; none of them block EP-6's upstream synthesis.

**1. Deterministic-replay durable execution with named steps.** §4 of this document fixes the shape; the implementation is v2. Deferred because (a) the v1 process-manager substrate covers ~90% of "workflow" use cases (sagas, choreography, multi-stream coordination) without paying the determinism cost, (b) named-step durability needs the journal-stream-per-workflow infrastructure plus the `step`/`sleep`/`awakeable` effect handler, and (c) re-entry on crash needs a workflow runtime that finds and resumes unfinished workflows on startup. Adding it post-v1 is mechanical; getting v1 right first is the priority.

**2. Awakeables.** A durable promise resolved by an external system, identified by an opaque id. Useful for human-in-the-loop ("wait for a manager to approve"), third-party callbacks ("wait for the payment processor's webhook"), agentic AI loops ("wait for the LLM to return a tool result"). Deferred because (a) the v1 alternative — receive the external event into a kiroku stream and let a process manager react — works for every awakeable use case, and (b) awakeables introduce a global-id namespace and an external-completion API (`signal :: AwakeableId -> Result -> IO ()`) that v1 has no consumer for. Per `docs/research/05-workflow-prior-art.md` §2 ("Avoid"): "Awakeables are powerful but introduce a global-id namespace and external-completion API; treat as a v2 feature, not v1."

**3. Child workflows.** A workflow spawned by a parent workflow, recorded in the parent's journal so the parent can wait on or cancel it. Deferred because (a) v1's process-manager-emit-command pattern composes — a PM that emits a command targeting another PM is the v1 analogue, (b) recording a child handle in the parent's journal requires the journal infrastructure §4 introduces, and (c) cancellation propagation across child boundaries is a v2 concern that touches every step's effect handler.

**4. Continue-as-new.** Snapshot the workflow's state, rotate its journal stream, resume against the rotated stream. Deferred because (a) v1's snapshot machinery (EP-4) handles the bounded-history case for process managers — a long-lived PM stream stays loadable as long as its snapshot is fresh, and (b) journal rotation is a v2-specific concern that only matters once `wf-<id>` streams exist.

**5. Versioning / patch API.** An explicit `patch :: PatchId -> Workflow Bool` primitive that records the patch decision in the journal so future replays observe the same branch. Deferred because (a) named steps already make most patches mechanical (rename a step to opt out; the new name has no journaled history so the new logic runs from scratch), and (b) patches that cross-cut multiple steps are rare and can be deferred to v2.5 if real demand emerges.

**6. Multi-region / global-ordering.** v1 is single-Postgres. Multi-region adds a global-position-across-regions question (a Postgres-only design has no answer for this without external coordination — Spanner-class storage or two-phase commit between regions, both of which contradict the "Postgres-native, library-shaped" thesis). Deferred until a customer demands it.

**7. Server-side scripted projections.** Rejected outright — `docs/research/05-workflow-prior-art.md` §7 ("Avoid") flags EventStoreDB's JavaScript projections as "operationally fragile and a debugging nightmare". keiro will not ship this in v2 either; the rejection is intentional. Listed here only to make the "no, never" decision explicit.

**8. Consumer-group sharding for category subscriptions.** When a single subscription handler can't keep up with a high-volume category, partition the keyspace across N workers with cooperative ownership. Deferred because (a) `docs/research/05-workflow-prior-art.md` §6 ("Avoid") notes Akka's cluster-sharding solution is "gorgeous in Scala/Akka and a nightmare to operate", and (b) v1's per-stream optimistic concurrency plus advisory-lock subscription claiming is sufficient until a real workload requires more. v2 adds it the moment a customer hits the throughput wall.

**9. Cluster-aware leadership.** v1 relies on advisory locks per subscription name to elect a single worker; v2 may add a more sophisticated leader-election story (etcd-style or Postgres `pg_advisory_xact_lock` with a heartbeat) when sharding lands.

**10. Schema registry.** A central registry of every event type's current schema, queried by consumers to validate compatibility before subscribing. Deferred because (a) EP-2's per-event-type version vector and consecutive upcasters cover the common case (one team, one repo, codecs versioned in source), and (b) registries earn their keep at organizational scale (multi-team, polyglot consumers) which keiro v1 does not target.

**11. LISTEN/NOTIFY push delivery.** Replace shibuya-kiroku-adapter's polling with a Postgres `LISTEN` channel for sub-second subscription latency. Deferred because (a) polling at 100ms is fine for v1 workloads, (b) LISTEN/NOTIFY introduces a long-lived connection per subscriber that complicates connection-pool sizing, and (c) the latency win matters only for interactive workflows, which v1 does not optimise for.

**12. Encryption at the field level / GDPR crypto-shredding.** Per-field AES with a key per data subject; "shredding" deletes the key, rendering the data unreadable. Deferred because (a) the threat model and key-management story (HSM? KMS?) is application-specific, and (b) keiro can offer the hooks (event-payload-pre-encrypt, event-payload-post-decrypt) without committing to a specific cipher or key store.


## 7. Schema additions

Tables v1 introduces (consolidated):

- `keiro_subscriptions` — extends kiroku's existing `subscriptions(subscription_name, last_seen)` with keiro-side metadata (lifecycle, configuration). Owned by EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §3).
- `keiro_outbox` — transactional outbox. Owned by EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §6).
- `keiro_inbox` — dedup-on-receive table. Owned by EP-3 (`docs/research/08-subscription-and-process-manager-design.md` §7).
- `keiro_snapshots` — sidecar snapshot table. Owned by EP-4 (`docs/research/09-snapshot-strategy.md` §2).
- `keiro_timers` — durable-timer table. Owned by this document (§3).

Tables v2 adds:

- `keiro_workflow_steps` — index of `(workflow_id, step_name)` for fast lookup of journaled steps without rescanning the journal stream. The journal itself stays in kiroku as the `wf-<workflowId>` stream; this table is a derived view for the workflow runtime's hot path. Owned by v2.
- `keiro_awakeables` — `(awakeable_id, owner_workflow_id, status, payload)` for §4's awakeable primitive. Owned by v2.

**Forward compatibility.** None of v2's additions invalidate v1's tables. v1 deployments can upgrade to v2 in place (run the v2 migration; v2 reads its own tables and ignores them when running a pure-v1 workload). The five v1 tables are stable contracts — EP-6's upstream-roadmap synthesis must record any changes that would force a non-trivial migration.


## 8. Operational comparison — keiro v1 vs prior art

One paragraph each, citing `docs/research/05-workflow-prior-art.md` for evidence. The takeaway is the positioning statement at the end.

**vs Temporal.** Temporal ships a custom server (frontend, history, matching, worker services) with pluggable persistence (Cassandra/MySQL/Postgres on the server side). A simple workflow with one timer produces ~10 history events; signals each generate at least one event plus a workflow task (`docs/research/05-workflow-prior-art.md` §1). The operational tax is the cluster — running it correctly across regions with the right capacity for history compaction and matching is a full-time SRE concern. keiro v1 is a library: workers are just OS processes that connect to Postgres, and the only persistent state is rows in tables your application already owns. Temporal's deterministic-replay model gives you cross-deploy resumption with strong guarantees; v1 keiro's process-manager substrate gives you the same coordination capability for ~90% of use cases without the cluster. v2's named-step durable execution closes the remaining 10% gap without copying Temporal's positional-history fragility.

**vs Restate.** Restate ships its own log+state engine (Bifrost replicated log + RocksDB state, snapshotted to object storage). Per-key serialization on Virtual Objects gives strong ordering, journaled `ctx.run`/`ctx.sleep`/`ctx.awakeable` give durable building blocks, and the SDK can suspend execution between journal entries to support FaaS-style stateless function hosts (`docs/research/05-workflow-prior-art.md` §2). The operational tax is the engine — running Bifrost + RocksDB + snapshot-to-S3 in production is a non-trivial commitment. keiro v1 declines to run a separate replicated log; the journal sits in Postgres alongside the rest of the application's data. v2's `step`/`sleep`/`awakeable` borrow Restate's vocabulary but live on Postgres rather than Bifrost; the suspend-between-journal-entries trick is irrelevant for an in-process Haskell library.

**vs DBOS.** DBOS is the closest prior art: a library that runs inside the application, Postgres-only, workflow state and step checkpoints in tables alongside business data (`docs/research/05-workflow-prior-art.md` §3). The transactional step (`@step` whose checkpoint commits in the same `BEGIN/COMMIT` as the side-effect's SQL write) is the killer Postgres-native primitive, and keiro v1 adopts it via `runCommandWithSql`. DBOS's "re-run from the top" durable-execution model is the same shape v2 keiro adopts. The differences: DBOS keys checkpoints by function name + invocation id (couples durability to identifier stability), where v2 keiro keys by named step (decouples durability from function names) — a lift from Inngest. DBOS does not maintain an event log; v1 keiro does (via kiroku) so domain events for projections sit alongside step checkpoints for resumability. The combined story — Postgres-only library + transactional step + named-step durability + first-class event log — is what v1+v2 keiro will offer that DBOS does not.

**Positioning statement.** keiro is a Haskell-first, Postgres-native, library-shaped event-sourcing engine with first-class process managers and durable timers in v1, and an explicit upgrade path to named-step durable execution in v2. No other Haskell library in the ecosystem occupies this slot (the closest — `eventful`, `eventium`, `eventsourcing` — are all event-store-only with no workflow story; see `docs/research/05-workflow-prior-art.md` §9). The competitive position is "keep what DBOS and Marten taught us; reject the Temporal/Restate ops tax; deliver the workflow surface as a Haskell effect rather than an external runtime".


## 9. Open questions for EP-6

The v1 substrate this document fixes raises three questions that touch upstream libraries (kiroku, keiki, shibuya). EP-6 (`docs/plans/6-upstream-roadmap-for-kiroku-and-keiki.md`) consolidates them into the upstream backlog.

**kiroku-side: process-manager state-stream naming convention.** v1 PMs name their state streams `pm-<pmName>-<correlationId>` (per `docs/research/08-subscription-and-process-manager-design.md` §5), and v2 workflows name their journal streams `wf-<workflowId>`. The question: should kiroku treat these as a *category* (so a subscription on the `pm-` category lets an operator observe every PM in the deployment) or leave them as ordinary streams named by convention? Treating `pm-` as a category requires kiroku to surface category subscription on a string-prefix predicate (currently `Category Text` uses an exact-match category derived from `stream_name` via the Eventide convention `category-id`). A prefix-or-stream-pattern subscription is a kiroku-side feature; if kiroku does not adopt it, keiro can compose category subscriptions by enumerating known PM names at registration time. EP-6 picks based on whether the operator-observability win justifies the upstream feature.

**keiki-side: should `step` carry a `compensate` direction for sagas?** v1 sagas are authored as ordinary process managers whose step function emits compensating commands on failure events. The keiki primitive `step :: SymTransducer phi rs s ci co -> (s, RegFile rs) -> ci -> Maybe (s, RegFile rs, Maybe co)` returns at most one event per command; a saga that needs to emit a compensating command on a *failure* event uses an ordinary edge in the transducer with `failure` in `ci`. Symmetrically: should the transducer expose a separate `compensate :: ci -> co -> Maybe co'` direction for the inverse? The argument for: makes saga compensation a first-class formalism rather than an application convention, supports the future SBV/z3 verification layer over compensation correctness. The argument against: sagas are a small-enough subset of process managers that the application convention works fine; adding a direction to `SymTransducer` complicates `compose`/`alternative`/`feedback1` and the verification story without obvious payoff. EP-6 picks based on whether keiki's roadmap already includes a verification milestone that wants compensation as a typed concept.

**shibuya-side: should the durable-timer worker reuse shibuya's supervisor?** Per §3, the timer-firing worker can be either a stand-alone OS process or a shibuya-supervised worker. Reusing shibuya gets free OpenTelemetry spans (timer fires become observable spans alongside subscription deliveries) and free shibuya-metrics gauges (timer-fire latency, queue depth). The cost: shibuya's supervisor today supervises *adapter*-shaped workers (a `Stream (Eff es) (Ingested es msg)` source plus a `Handler es msg`); a timer worker is not adapter-shaped (it polls a table directly). Either shibuya's supervisor needs a non-adapter-shaped worker entry point, or keiro wraps the timer worker as a degenerate adapter. EP-6 picks based on whether shibuya's roadmap includes generalising the supervisor.


## 10. How to verify

Acceptance: a reviewer who reads only this document and `docs/research/05-workflow-prior-art.md` can answer:

- *What does "workflow" mean in keiro v1?* Process managers (per §2.1, designed in EP-3) plus durable timers (§3) plus the supporting v1 primitives in §2.
- *What does it explicitly **not** mean in v1?* Deterministic-replay durable execution, awakeables, child workflows, continue-as-new, versioning/patch APIs, multi-region, schema registries, LISTEN/NOTIFY push delivery, consumer-group sharding, field-level encryption (§6).
- *What stretch features belong in v2, and what is the upgrade path?* Named-step durable execution (§4) on top of the v1 process-manager substrate (§5). Awakeables and child workflows compose on top of the journaled-function machinery §4 introduces. Schema additions are forward-compatible (§7) — v1 deployments upgrade in place.
- *What operational complexity does v1 avoid?* Running a custom workflow server (Temporal-style), running a separate replicated log (Restate-style), running scripted projections (EventStoreDB-style), running cluster-sharded subscribers (Akka-style). The operational story is "workers are OS processes that connect to Postgres", per §8.

The verification is documentary, not empirical. Each cross-reference in this document points at either a sibling design document (`docs/research/06-` through `docs/research/09-`), the literature survey (`docs/research/05-workflow-prior-art.md`), or the parent MasterPlan's Decision Log. A reviewer can walk through every claim without running new code.


## 11. Summary

keiro v1 ships event-sourced process managers (EP-3), durable timers (this document §3), the transactional outbox/inbox (EP-3), inline and async projections (EP-3), snapshots (EP-4), and idempotent commands (EP-1). Together these primitives cover the saga and choreography use cases that account for ~90% of "workflow" demand without committing to a deterministic-replay runtime.

keiro v2 adds named-step durable execution on a journaled `Workflow es a` effect (§4), with sleeps backed by §3's timer table and awakeables backed by a new `keiro_awakeables` table. The journal lives in kiroku as `wf-<workflowId>` streams, sharing the storage and observability substrate with v1's PM streams. The v1-to-v2 upgrade path is mechanical (§5): a process manager *is* a workflow with one explicit step; conversely, a workflow is a process manager whose step function happens to be journaled call-by-call.

Three open questions go to EP-6 for upstream synthesis (§9): whether kiroku exposes a prefix-style category subscription for `pm-`/`wf-` streams, whether keiki's `SymTransducer` gains a `compensate` direction, and whether shibuya's supervisor hosts the timer-firing worker. None of these block v1; all of them are quality-of-life questions that EP-6 can prioritise alongside the upstream backlog from EP-1 through EP-4.
