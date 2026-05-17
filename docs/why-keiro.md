# Why keiro — 経路

This document motivates keiro against three adjacent categories of system its
users would otherwise reach for:

1. **Traditional event-sourcing frameworks** — Eventide / message-db, Marten,
   EventStoreDB, Akka Persistence / Lagom, and the Haskell crowd
   (`eventful`, `eventium`, `eventsourcing`).
2. **Generic-step workflow engines** — Camunda / Zeebe, Airflow, AWS Step
   Functions, Argo Workflows, Netflix Conductor, and the long tail of
   BPMN/DAG runners.
3. **Durable-execution engines** — Temporal / Cadence, Restate, Inngest,
   DBOS.

It assumes the reader has skimmed [`README.md`](../README.md). It does not
substitute for the design documents in [`docs/research/`](research/); where
a claim depends on a specific design decision, the relevant research file is
cited inline.

The intent is honest, not promotional. Section 7 enumerates the things keiro
deliberately gives up and the situations in which one of the three
alternative categories is the better answer.

The picture is keiro **once fully implemented in all phases** — v1
(event-sourced process managers + durable timers + transactional outbox/inbox
+ inline/async projections + snapshots + idempotent commands) and v2
(named-step durable execution journaled into the same Postgres event log).
Pre-1.0 caveats are isolated in §7.4.

---

## 1. The thesis in one paragraph

Keiro composes a Postgres-backed append-only event store
([kiroku](https://github.com/shinzui/kiroku)), a pure functional core built
on a symbolic-register finite-state transducer
([keiki](https://github.com/shinzui/keiki)), and a supervised subscription
engine ([shibuya](https://github.com/shinzui/shibuya)) into a single Haskell
library that delivers event sourcing, process-manager workflows, and
named-step durable execution against **one mathematical object** —
`SymTransducer phi rs s ci co` — and **one persistence substrate** — your
existing Postgres database. There is no separate workflow server, no
separate replicated log, no parallel storage path for "workflow state" vs
"domain events", no distinction in tooling or observability between an
aggregate, a process manager, and a durable workflow. The same fold
hydrates all three; the same optimistic-concurrency append commits all
three; the same operator dashboards inspect all three.

Every other system on the market makes the user assemble this picture
themselves out of categorically different components.

---

## 2. The single-formalism claim

The most consequential design decision in keiro — and the one most
responsible for the benefits enumerated below — is that **the keiro ⇄
keiki contract is keiki's native `SymTransducer phi rs s ci co`, not a
Decider facade** (`docs/masterplans/1-keiro-research-foundation.md`
Decision Log entry 2026-05-04;
`docs/research/06-command-cycle-design.md` §"The contract derivation").

A `SymTransducer` is a finite-state machine with:

| Type parameter | What it carries                                                 |
| -------------- | --------------------------------------------------------------- |
| `phi`          | Predicate carrier — guards on edges (v1: Haskell functions; v2: SBV/z3 symbolic) |
| `rs`           | Slot-list of the typed register file (timers, counters, correlation ids) |
| `s`            | Control vertex — the state machine's "place" in the graph       |
| `ci`           | Input alphabet — commands the machine accepts                   |
| `co`           | Output alphabet — events the machine emits                      |

From this one shape, keiro mechanically derives every primitive a working
event-sourcing-and-workflow system needs:

- An **aggregate** is a `SymTransducer` whose `ci` is its commands and `co`
  is its events.
- A **process manager** is a `SymTransducer` whose `ci` is the events it
  consumes from upstream categories and `co` is the commands it dispatches
  downstream — with timers, retry counters, and correlation ids living as
  typed `rs` slots
  (`docs/research/08-subscription-and-process-manager-design.md` §5;
  `docs/research/10-workflow-roadmap.md` §2).
- A **saga** is a process manager whose `co` includes compensating
  commands, authored by the application as ordinary edges
  (`docs/research/10-workflow-roadmap.md` §2.4).
- A **v2 durable workflow** is a `SymTransducer` whose `co` is a sequence of
  `StepRecorded { name, result }` events journaled into a `wf:<workflow-name>-<workflow-id>`
  stream, so a workflow function sits on top as sugar over named-step
  journaling (`docs/research/10-workflow-roadmap.md` §4).

A v1 process manager *literally is* a v2 workflow with one explicit step;
the upgrade path is mechanical, not a rewrite
(`docs/research/10-workflow-roadmap.md` §5).

This is the headline win. Every benefit in the rest of this document is
either "you only have to learn one thing" or "you only have to operate one
thing" or "you only have to evolve one thing".

---

## 3. Code maintenance

### 3.1 Refactoring without fear of replay non-determinism

Temporal couples workflow durability to the **exact AST of user code**
between deploys. Reordering two statements, renaming an `await`, or
upgrading an SDK that changed an internal helper can corrupt every
in-flight workflow's history with a non-determinism error. Versioning
through `getVersion` / `patched` is folklore that becomes impossible to
retire (`docs/research/05-workflow-prior-art.md` §1, "Avoid").

Keiro v2 takes Inngest's lift: **named steps are the durability
discriminator** (`docs/research/10-workflow-roadmap.md` §4). A step is
identified by a string label the author chose — `step "charge-card"` — not
by its position in the function body. Reordering steps in source has no
effect on durability; renaming a step is a deliberate operator action
(rename → the new name has no journaled history → the new logic runs from
scratch). Cross-version evolution becomes a compile-time and lint problem,
not a runtime non-determinism nightmare.

For traditional event-sourcing libraries the maintenance pain is different
but real: every refactor of the `evolve` function risks breaking replay of
historical events. Keiro inherits keiki's discipline — `evolve` (and its
`SymTransducer` realisation) is a **total fold** over a typed event sum,
so the compiler catches every missed case; an unknown event type at the
boundary fails loudly rather than silently dropping
(`docs/research/02-keiki-decide-loop.md`).

### 3.2 The typed register file makes workflow state legible

Generic workflow engines (Camunda, Conductor, Step Functions) store
workflow state as an opaque JSON blob. Reaching for a slot that doesn't
exist is a runtime error discovered in production.

Durable-execution engines store step results as opaque blobs keyed by step
name. Same failure mode at the joints.

Traditional event-sourcing libraries put state in a per-aggregate Haskell
record, which the compiler does check — but they have no first-class
concept of *workflow state*. Timer fire-times, retry counters, and
correlation ids end up scattered across application code, projection
tables, or ad-hoc fields on the aggregate.

Keiro inherits keiki's `RegFile rs`: a typed heterogeneous tuple where
each slot is a `(Symbol, Type)` pair. The compiler tracks every slot.
Snapshot evolution is gated by a `regfile_shape_hash` discriminant so a
schema-incompatible snapshot falls through to full replay rather than
loading the wrong shape (`docs/research/09-snapshot-strategy.md` §2).
Reading an uninitialised slot fails loudly with a named error
(`Keiki/Generics.hs:emptyRegFile`).

The maintenance consequence: when you open a process manager six months
later and ask "what state does this thing actually carry?", the answer is
in the type signature, not in three different tables and a Slack thread.

### 3.3 Composition is mathematical, not ad-hoc

Generic workflow engines provide composition through a YAML / XML / GUI
where one DAG calls another. The composition operators are unprincipled:
"sub-workflow" usually means "fork-and-forget with bespoke result
plumbing".

Durable-execution engines provide composition through SDK calls
(`startChildWorkflow`, `executeChildWorkflow`). The semantics — when does
the parent see the child's result, how is cancellation propagated, what
happens to compensations — are documented but not derivable; you read the
manual.

Keiki ships three principled composition combinators on `SymTransducer`
(`Keiki/Composition.hs`, surveyed in
`docs/research/02-keiki-decide-loop.md` §"Composition"):

- `compose t1 t2` — sequential composition, unifying alphabets at the
  midpoint, register files concatenated.
- `alternative t1 t2` — disjoint-input dispatch.
- `feedback1 t` — single-step feedback loop.

These are the same combinators used to build tractable cascades of finite
automata in formal-methods textbooks. They are total, well-typed, and
their semantics are derivable from the underlying transducer algebra.

The maintenance consequence: composing a saga out of two existing process
managers, or splitting a monolithic workflow into two coordinated ones, is
a refactor the type checker can guide. There is no "child workflow"
runtime concept to learn; composition is a function on values.

### 3.4 One vocabulary across event sourcing and workflows

Teams using a traditional ES library plus a separate workflow engine
maintain two conceptual stacks: aggregates / events / projections /
optimistic concurrency on one side, workflow / activity / signal /
heartbeat / continue-as-new / signal-with-start on the other. New hires
learn both. Bugs cross the boundary in unpredictable ways.

Teams using DBOS get one library but two persistence pictures: business
data in their schema, workflow state in DBOS-managed tables, with the
transactional step as the bridge.

Keiro has one vocabulary. An aggregate is a `SymTransducer`; a process
manager is a `SymTransducer`; a v2 workflow is a `SymTransducer` with a
journal. Hydration is `SymTransducer.reconstitute`. Writing an event is
`SymTransducer.omega` followed by `kiroku.appendToStream`. The runtime
glue is in the same library. New hires learn one set of types.

### 3.5 The transactional step closes a class of bugs by construction

The single largest source of subtle bugs in event-sourcing systems is the
gap between "I appended the domain event" and "I updated the read model /
sent the message to Kafka / scheduled the timer". A crash between the two
leaves the system in a state where the event happened and the consequence
did not — or vice versa, with idempotency duct-taped on after.

Keiro adopts DBOS's transactional step as a first-class primitive
(`docs/research/05-workflow-prior-art.md` §3, "Steal";
`docs/research/06-command-cycle-design.md` for the `runCommandWithSql`
shape). The user supplies a `Hasql.Transaction.Transaction` that:

- appends the new domain events to kiroku (with optimistic concurrency),
- updates inline projection rows in the user's tables,
- inserts a row into the transactional outbox (`keiro_outbox`),
- inserts a row into the durable-timer table (`keiro_timers`),
- writes a process-manager state-advance event,

— and Postgres commits all of it together or none of it. The maintenance
consequence: the compensating-action plumbing that haunts every
event-sourcing system at scale (saga middleware, idempotency keys
everywhere, "drain script" CLIs) collapses into a single combinator.
Inline projections give read-your-own-writes within the append transaction
— the Marten killer feature, but Haskell-typed.

---

## 4. Understanding business workflows

### 4.1 The state machine is the business workflow

Generic workflow engines render workflows as DAGs because the underlying
machinery is "sequence of generic steps". A loan application — *applied*
→ *underwriting* → *approved* | *rejected* — is expressible as a DAG, but
the *business semantics* (which states allow which commands; which
transitions can fire which events; what timer to start when entering
*underwriting*) live in code attached to nodes, not in the diagram itself.
Reading the diagram tells you the topology; understanding the workflow
requires reading the attached code too.

Durable-execution engines render workflows as imperative functions. The
business semantics are spread across `if` branches and `await` calls. A
new engineer reads the function top-to-bottom and reconstructs the state
machine in their head.

Keiki's `SymTransducer` *is* the state machine. The control vertex `s` is
a Haskell sum — `Applied | Underwriting | Approved | Rejected` — that the
compiler enumerates. The `edgesOut` function at each vertex lists every
admissible transition with its guard, its register-file update, and its
emitted event. The diagram and the code are the same artifact, derivable
from each other.

The understanding consequence: a product manager and an engineer can
literally point at the same `SymTransducer` definition and agree on what
the workflow does. There is no diagram-vs-code drift, because there is no
diagram separate from the code.

### 4.2 Process managers and aggregates use the same mental model

In traditional ES + separate-workflow setups, the team learns:
- Aggregates have *commands*, *events*, and *invariants*.
- Process managers have *event subscriptions*, *correlation*, and
  *commands they dispatch*.
- Sagas have *steps*, *compensations*, and *state*.

Three vocabularies for three conceptually similar things.

In keiro all three are the same shape: `SymTransducer phi rs s ci co`.
What differs is the population of the type parameters
(`docs/research/10-workflow-roadmap.md` §5):

| Role            | `ci` (input)                | `co` (output)                       |
| --------------- | --------------------------- | ----------------------------------- |
| Aggregate       | Domain commands             | Domain events                       |
| Process manager | Upstream domain events      | Downstream domain commands          |
| Saga            | Upstream events + failures  | Forward + compensating commands     |
| v2 workflow     | (Implicit — function body)  | `StepRecorded { name, result }`     |

A team that has internalised the aggregate pattern can read a process
manager without learning a new vocabulary; the only news is "the input
alphabet is some other aggregate's output alphabet". Sagas are not a
separate primitive; they are process managers whose authors emit
compensating commands when they see failure events
(`docs/research/10-workflow-roadmap.md` §2.4).

### 4.3 ε-edges express invisible state advancement

Real business workflows have transitions that don't correspond to a
visible event — *"if 30 days pass without confirmation, silently expire"*,
*"on entering this state, atomically initialise the retry counter"*. In
generic workflow engines these become sentinel events or boolean flags on
the aggregate. In durable-execution engines they become an internal `step`
whose only purpose is to mark a state advance.

Keiki supports **ε-edges** natively: edges with `output = Nothing` advance
the control vertex and update the register file without emitting an event
(`docs/research/02-keiki-decide-loop.md` §"The Decide"). The workflow
diagram remains faithful — there is no fake event in the log — and replay
honours the invisible transition.

The understanding consequence: the event log records what the *business*
considers events; internal bookkeeping doesn't pollute the audit trail.

### 4.4 Symbolic verification (v2)

Generic workflow engines have no formal verification story. Durable
execution engines have none either; the best you get is a replay test in
CI that catches non-determinism after the fact.

Keiki's predicate carrier `phi` is parameterised. The v1 carrier is
`HsPred rs ci` — ordinary Haskell functions, fast and unverifiable. The v2
carrier targets SBV/z3 symbolic predicates, at which point a `SymTransducer`
becomes amenable to mechanical questions:

- *Is state X reachable?*
- *Can two edges from the same vertex fire on the same input? (non-determinism)*
- *Does any edge ever leave a register slot uninitialised?*

These are the questions auditors ask about regulated workflows (loan
underwriting, KYC, claim adjudication) and that no other system on this
list answers without a separate modeling tool. Keiro's path to symbolic
verification is built into the formalism, not bolted on.

The understanding consequence: complex business workflows that today live
in TLA+ or Alloy specs *plus* a separate executable implementation can
collapse to a single artifact.

### 4.5 The audit trail is the source of truth for everything

Generic workflow engines store an execution log separate from any business
event log; reconciling the two is a downstream-of-production project.

Durable-execution engines store a workflow history separate from any
domain event log. To answer "what did the order's state look like at the
moment the workflow charged the card", you correlate two stores.

Keiro stores everything as kiroku streams in one Postgres database. A v1
process manager's state lives in a `pm:<pmName>-<correlationId>` stream; a
v2 workflow's journal lives in a `wf:<workflow-name>-<workflow-id>` stream; aggregate
events live in their own per-aggregate streams; all of them share
kiroku's gap-free contiguous global position
(`docs/research/00-overview.md`, "kiroku is solid";
`docs/research/10-workflow-roadmap.md` §4 "Why kiroku for the journal").
An auditor (or an SRE chasing a bug) reads streams from one store with one
query language.

---

## 5. Operating complex systems

### 5.1 No separate cluster to run

Temporal ships a custom server (frontend, history, matching, worker
services). Restate ships its own log+state engine (Bifrost replicated log
+ RocksDB state, snapshotted to object storage). EventStoreDB ships its
own database. Camunda / Zeebe ships a clustered orchestration engine.
Each is a non-trivial SRE commitment with its own failure modes,
upgrade story, capacity-planning model, and on-call playbook
(`docs/research/05-workflow-prior-art.md` §1, §2, §7).

Keiro is a Haskell library you import (`docs/research/00-overview.md`).
Workers are OS processes that connect to the same Postgres your
application already uses. The only new persistent state is rows in tables
your DBA already knows how to back up.

For a team that already runs Postgres in production, the additional
operational surface is approximately zero. For a team that doesn't, the
question is whether they want to add Postgres or add Postgres-plus-a-new
clustered system.

### 5.2 Strategy E means subscribers don't need watermark machinery

Most event-sourcing systems on Postgres use `bigserial` for the global
position. Under concurrent transactions, position N+1 can commit before N,
so a naive subscriber that advances on each observed position can skip
events. Marten solves this with a high-water-mark daemon that only feeds
contiguous positions to projections. The HWM is a real piece of
operational machinery — its lag is a metric, its stalls are an incident
class.

Kiroku takes a different path: **Strategy E** uses an atomic `UPDATE …
RETURNING` on the `$all` row inside the same transaction that inserts
events, so global positions are gap-free contiguous (1, 2, 3, …) with
immediate read-your-own-writes (`kiroku/docs/DESIGN.md` §"Core Design
Choice: Strategy E"; settled architectural decision per
`docs/research/05-workflow-prior-art.md` §"Corrections note";
`docs/research/08-subscription-and-process-manager-design.md` §4;
`docs/research/11-upstream-roadmap.md` §9.1). Subscribers advance their
`last_seen` to any observed position. There is no HWM, because there are
no gaps for it to detect.

The operational consequence: one fewer moving part. No HWM-lag dashboard,
no "subscriber stuck behind a stalled writer" incident, no operator
intuition to develop about "is this gap real or transient".

### 5.3 Snapshots are advisory, never load-bearing

Most systems that snapshot aggregates either (a) treat the snapshot as
authoritative and crash if it's malformed, or (b) layer a custom
fall-through path that's tested less than the main path.

Keiro's snapshots are *advisory* (`docs/research/09-snapshot-strategy.md`
§2). The hydration pipeline is a Streamly `Stream → Fold`; a snapshot
short-circuits it by parameterising the source's start cursor and the
fold's initial accumulator — same pipeline, no parallel code path. If the
`state_codec_version` or `regfile_shape_hash` discriminant doesn't match,
the snapshot is ignored and full replay runs. Operators can `TRUNCATE
keiro_snapshots` at any time to force re-hydration; nothing breaks.

The operational consequence: snapshot bugs are performance regressions,
not correctness incidents. The "wait, did we deploy a bad snapshot
encoder" pager is replaced with "hydration got slower; truncate and
investigate".

### 5.4 The transactional outbox / inbox in one transaction with the event

Every system that crosses a transactional boundary to call an external
service eventually invents the outbox pattern. In most stacks it's
plumbing the team writes themselves, with subtle bugs around delivery
ordering, dedup, and dead-lettering.

Keiro ships the outbox as a first-class primitive backed by `pgmq-hs`
(`docs/research/08-subscription-and-process-manager-design.md` §6, §7;
`docs/research/10-workflow-roadmap.md` §2.3). The `keiro_outbox` row is
inserted in the same `Hasql.Transaction.Transaction` as the event append;
a separate drain worker enqueues to pgmq with `SELECT … FOR UPDATE SKIP
LOCKED` and deletes the outbox row in the same transaction. The inbox
(`keiro_inbox`) is the dedup-on-receive dual.

The operational consequence: "did the event happen exactly when the
external call happened" is true by construction.

### 5.5 The event log is the operational debugging surface

When a generic workflow engine misbehaves, you read its execution log,
which is in its proprietary format and doesn't include domain context.
When a durable-execution workflow misbehaves, you read its workflow
history, which is in its proprietary format and doesn't include domain
events except as serialised activity inputs. When something goes wrong
across the workflow / domain boundary, you correlate two stores in two
formats.

When keiro misbehaves, the operator opens psql and runs:

    SELECT global_position, stream_name, type, data, metadata
      FROM kiroku.events
     WHERE stream_name LIKE 'pm:orderfulfillment-%'
        OR stream_name = 'order-42'
     ORDER BY global_position;

The process manager's state-advance events, the order aggregate's domain
events, every `TimerFired`, every emitted command — all in one query, in
the same format, on one timeline.

### 5.6 Observability is uniform across aggregates, PMs, and workflows

Shibuya emits OpenTelemetry spans for every subscription delivery, every
handler invocation, and — now that kiroku-store ships
`Kiroku.Store.Transaction.runTransactionAppending` (and the matching no-retry
sibling, the `appendToStreamTx` building block, and the bare `runTransaction`
escape hatch; see `docs/research/11-upstream-roadmap.md` §4.1's 2026-05-10
corrections note) — every transactional step.
Because PMs and v2 workflows are built on the same kiroku streams + the
same shibuya supervision, their spans, gauges, and histograms slot into
the same dashboard. There is no parallel "workflow engine UI" to
maintain.

---

## 6. Concrete deltas vs each category

### 6.1 vs traditional event-sourcing frameworks

Compared to Eventide / message-db, Marten, EventStoreDB, Akka Persistence,
and the Haskell crowd:

**Keiro keeps**:
- Optimistic concurrency on stream version (Eventide, Marten, all of them).
- Per-stream serialisation discipline (Akka actors, Eventide's advisory
  lock).
- Three projection lifecycles — inline / async / live (Marten).
- Decider-style pure decide+evolve (Eventide; Chassaing; eventful) — though
  expressed as `SymTransducer`, *not* `Keiki.Decider`, which is a legacy
  facade keiro must never rely on (`docs/research/05-workflow-prior-art.md`
  §"Corrections note").
- The Eventide storage shape: stream-name convention `category-id`, single
  events table (kiroku adopts this in spirit).

**Keiro adds**:
- A first-class workflow story (process managers in v1, named-step durable
  execution in v2). Eventide and Marten leave workflows as application
  homework; the Haskell crowd has no story at all.
- The transactional step (DBOS) — append events + write projection rows +
  insert outbox + start timer in one Postgres transaction.
- Typed register file (`RegFile rs`) for workflow-shaped state
  (timers, retries, correlation ids).
- Strategy-E gap-free positions (no HWM machinery).
- ε-edges for invisible state advancement.
- A path to symbolic verification of business workflows.

**Keiro removes**:
- The HWM operational tax (Marten).
- Pluggable-everything (Akka). Postgres only, hasql only, effectful only —
  discipline-as-feature.
- Server-side scripted projections (EventStoreDB) — operationally fragile,
  rejected outright (`docs/research/05-workflow-prior-art.md` §7).
- Cluster-membership single-writer guarantees (Akka). Optimistic
  concurrency on stream version is dramatically simpler and gives the same
  correctness.

### 6.2 vs generic-step workflow engines

Compared to Camunda / Zeebe, Airflow, AWS Step Functions, Argo Workflows,
Netflix Conductor:

**The fundamental mismatch.** Generic-step engines model workflows as
sequences of opaque steps (a "task" or "activity") wired into a DAG or
BPMN diagram. They're optimised for *the workflow being the application*
— ETL pipelines, BPM processes, ML training DAGs, infrastructure
orchestration.

Keiro is optimised for *the workflow being part of an application that
also has aggregates, projections, and an event log*. A keiro workflow
isn't a separate artifact; it's a `SymTransducer` that consumes events
from the same log every other piece of the system reads.

**Keiro wins decisively when**:
- The application is an event-sourced system and the workflow needs to
  consume domain events and dispatch domain commands. Generic engines
  treat your event log as an external system; keiro treats it as the
  primary substrate.
- Business correctness depends on transactional atomicity between
  workflow state advancement and domain side-effects. Generic engines
  cannot give this; their state lives outside your transaction boundary.
- Auditability requires that workflow execution and domain events sit on
  one timeline.
- The workflow's state is structured (a state machine with named places)
  rather than a free-form sequence of steps.

**Generic engines win when**:
- The workflow really is a free-form sequence of opaque steps (an ETL DAG,
  a CI pipeline) where the structure is the value.
- Multi-language SDKs are required (Camunda has Java/JS/Python/.NET/Go;
  keiro is Haskell-only).
- A graphical authoring UI is required for non-developers (BPM use cases).
- The team is not Haskell-fluent and won't be.

### 6.3 vs durable-execution engines

Compared to Temporal / Cadence, Restate, Inngest, DBOS:

**vs Temporal / Cadence.** Temporal ships a custom clustered server with
pluggable persistence (Cassandra/MySQL/Postgres on the server side). A
simple workflow with one timer produces ~10 history events; signals each
generate at least one event plus a workflow task. The operational tax is
the cluster — running it correctly across regions with the right capacity
for history compaction and matching is a full-time SRE concern
(`docs/research/05-workflow-prior-art.md` §1). Temporal couples
determinism to the exact AST of user code; cross-version workflow
evolution requires `getVersion`/`patched` versioning folklore.

Keiro v1 is a library: workers are OS processes that connect to Postgres,
the only persistent state is rows in tables your application already
owns. Keiro v1's process-manager substrate covers the ~90% of workflow
use cases (sagas, choreography, multi-stream coordination) without paying
the cluster cost. Keiro v2 closes the remaining 10% gap with named-step
durable execution (Inngest's UX win) without inheriting Temporal's
positional-history fragility (`docs/research/10-workflow-roadmap.md` §4).

Temporal wins when: multi-language SDKs are mandatory, the team already
operates Cassandra at scale, deterministic-replay-over-arbitrary-code is a
hard requirement.

**vs Restate.** Restate ships its own log+state engine (Bifrost +
RocksDB) and offers per-key serialisation on Virtual Objects with
journaled `ctx.run` / `ctx.sleep` / `ctx.awakeable` building blocks. The
operational tax is the engine; the compensating win is a beautiful API
for FaaS-style stateless function hosts that can suspend mid-journal
(`docs/research/05-workflow-prior-art.md` §2).

Keiro v2 borrows Restate's vocabulary (`step` / `sleep` / `awakeable`)
but lives on Postgres rather than Bifrost. The suspend-between-journal-
entries trick is irrelevant for an in-process Haskell library; in
exchange we get one fewer system to operate.

Restate wins when: workloads are FaaS-shaped (stateless function hosts,
function execution can outlive a single process), the team prefers
managing a separate engine to managing more Postgres, multi-language
SDKs are required.

**vs Inngest.** Inngest is operationally simple (the executor calls your
function over HTTP for each step) and ergonomically excellent (named
steps, event-driven triggers, concurrency / rate / debounce as
first-class) (`docs/research/05-workflow-prior-art.md` §4). The trade-off
is HTTP-per-step latency and the executor-as-separate-service deployment
model.

Keiro v2 borrows Inngest's named-step durability discriminator
wholesale. Where it diverges: workflow execution stays in-process, the
journal lives in Postgres, and the workflow surface is part of a larger
event-sourcing engine rather than the entire library.

Inngest wins when: the application is JavaScript/TypeScript, HTTP-per-
step latency is acceptable, the team wants a hosted executor.

**vs DBOS.** DBOS is the closest prior art: a library that runs inside
the application, Postgres-only, workflow state and step checkpoints in
tables alongside business data. The transactional step is the killer
Postgres-native primitive (`docs/research/05-workflow-prior-art.md` §3).
Keiro v1 adopts the transactional step directly (via `runCommandWithSql`).

Where keiro differs from DBOS:
- DBOS keys checkpoints by function name + invocation id, coupling
  durability to identifier stability. Keiro v2 keys by named step
  (Inngest's lift), decoupling durability from function names so
  refactoring is safe.
- DBOS does not maintain an event log; it has step checkpoints but no
  domain-event story. Keiro maintains kiroku as the canonical event log
  *and* journals workflow steps into the same store, so domain events for
  projections sit alongside step checkpoints for resumability.
- DBOS is Python/TypeScript-first; keiro is Haskell-first.
- Keiro's process-manager substrate (event-sourced coordinators with
  typed register files) has no DBOS analogue.

The combined story — Postgres-only library + transactional step +
named-step durability + first-class event log + symbolic-verifiable
workflows — is what the v1+v2 keiro stack offers and DBOS does not.

DBOS wins when: the team wants TypeScript or Python, doesn't need an
event-sourcing layer, doesn't need named-step durability, doesn't need
first-class process managers.

---

## 7. Honest downsides

This section enumerates the things keiro deliberately gives up, the
situations in which one of the alternatives is the better answer, and the
work that is incomplete today.

### 7.1 Haskell-only

There are no Java, Python, JS, Go, or .NET SDKs and there will not be.
`SymTransducer` and the runtime are Haskell-typed end to end. Teams whose
service estate is polyglot need a workflow surface that speaks every
language they ship; keiro does not.

If multi-language SDKs are a hard requirement, the answer is Temporal,
Restate, or Inngest. If the application is in TypeScript, the answer is
DBOS or Inngest. If the application is BPM-shaped with non-developer
authors, the answer is Camunda.

### 7.2 Postgres-only, single-region

Keiro v1 is single-Postgres; v2 does not change this
(`docs/research/10-workflow-roadmap.md` §6.6). Multi-region durable
execution requires either external coordination (Spanner-class storage)
or two-phase commit between regions, both of which contradict the
"Postgres-native, library-shaped" thesis. Teams whose correctness story
requires synchronous global ordering across regions need Temporal Cloud
or Restate's Bifrost.

### 7.3 Steeper learning curve than a Decider library

A team adopting keiro is signing up to learn the `SymTransducer`
formalism: the typed register file `RegFile rs`, ε-edges, the predicate
carrier `phi`, the composition combinators. This is a richer API than the
4-field `Decider` record (`decide`, `evolve`, `initialState`,
`isTerminal`) every event-sourcing tutorial uses
(`docs/research/02-keiki-decide-loop.md`).

The pedagogical trade-off: `Decider` is easy to learn and gives no
workflow leverage; `SymTransducer` requires a longer onboarding and gives
the entire workflow story. Teams writing simple aggregates and no
workflows pay the formalism cost without using its features. We argue the
cost is small (you don't *use* `RegFile rs` if you don't need it) but
won't pretend it's zero.

### 7.4 Pre-1.0 today

The repository is currently in research phase
(`README.md`, "Status"). What exists is design documents and validating
spikes; there is no production-ready Haskell library yet. The MasterPlan
[`docs/masterplans/1-keiro-research-foundation.md`](masterplans/1-keiro-research-foundation.md)
sequences the design effort into six child plans; a separate
implementation MasterPlan ships the production library.

Teams that need to ship today should pick a system that exists today —
DBOS, Temporal, Marten, Eventide. Teams evaluating where to invest for
the next 18 months can reasonably consider keiro now, with the
understanding that the implementation is downstream of the research.

### 7.5 v1 lacks deterministic-replay durable execution

Per `docs/research/10-workflow-roadmap.md` §4, deterministic-replay
durable execution is v2. v1 ships event-sourced process managers + durable
timers, which cover sagas, choreography, and multi-stream coordination —
but not "I want to write an imperative function and have it survive
crashes mid-line".

If imperative durable functions are a v1-launch blocker, the answer is
DBOS (Postgres library) or Temporal/Restate (separate cluster). If
process-manager-style coordination is acceptable until v2, keiro v1 is
already enough.

### 7.6 No graphical workflow authoring

Generic workflow engines ship visual designers (Camunda Modeler,
Conductor UI, Step Functions Workflow Studio) so non-developers can
author workflows. Keiro has no plan to ship one. `SymTransducer`
definitions are Haskell source, and that's the medium.

For BPM use cases where a business analyst owns the workflow, this is
disqualifying. For engineering-owned workflows where the source-of-truth
is code, the absence of a designer is a feature: there's no diagram-vs-
code drift to manage.

### 7.7 Compile-time and tooling overhead

Heavy use of type-level slot lists (`RegFile rs`), kind-polymorphic
predicates, and composition combinators that thread typed register files
through means GHC works hard. Compile times for large transducer
compositions will be longer than for plain Haskell records, and error
messages on type mismatches will be richer (read: longer) than for a
plain Decider. Teams that want a casual scripting experience are picking
the wrong tool; teams that value compile-time guarantees on workflow
shape get what they paid for.

### 7.8 Symbolic verification is v2 and conditional

The path to SBV/z3 verification of business workflows
(§4.4) depends on keiki shipping the v2 predicate carrier. Today the
predicate carrier is `HsPred rs ci` — ordinary Haskell functions, not
symbolically tractable. The verification story is real but is a future
deliverable, not a 2026 capability.

### 7.9 Three open questions still going through EP-6

Per `docs/research/10-workflow-roadmap.md` §9 and
`docs/research/11-upstream-roadmap.md`, three substrate questions remain:
- Whether kiroku exposes a prefix-style category subscription for `pm:` /
  `wf:` streams (vs. enumerated category subscription at registration
  time).
- Whether keiki's `SymTransducer` gains a `compensate` direction (vs.
  application-authored compensation events).
- Whether shibuya's supervisor hosts the timer-firing worker (vs. a
  stand-alone OS process).

None of these block v1 implementation, but they will land before the
first stable release. The shapes above describe the endpoint each
question converges to; the chosen branch may shift details.

---

## 8. When to choose keiro

Choose keiro when **at least three** of the following are true:

- The application is event-sourced (or will be) and workflow logic needs
  to consume / emit domain events as first-class citizens, not as
  external integrations.
- The team is Haskell-fluent and values type-checked workflow state.
- Postgres is already in production and adding a separate workflow
  cluster is unattractive.
- Auditability requires workflow execution and domain events on one
  timeline, in one query.
- Workflows are state machines with named states, not free-form DAGs of
  opaque steps.
- Long-term plan benefits from formal verification of workflow
  correctness (regulated industries, financial services, healthcare).
- The team values "library you import" over "platform you operate".

Do **not** choose keiro when:

- Polyglot SDKs are mandatory.
- The team is not Haskell-fluent and won't be.
- Multi-region synchronous global ordering is a correctness requirement.
- The use case is BPM with non-developer authors and a designer UI is
  required.
- The workflow is genuinely a DAG of opaque steps (ETL, CI, ML training
  pipelines) and the event-sourcing layer adds no value.
- A production-ready library is needed in 2026 (today's keiro is
  pre-implementation; the design is in flight).

---

## 9. Summary

Once fully implemented, keiro delivers event sourcing, process-manager
coordination, and named-step durable execution on **one mathematical
object** (`SymTransducer phi rs s ci co`), **one persistence substrate**
(your Postgres), and **one runtime story** (a Haskell library you
import). Every other system on the market makes you assemble this picture
yourself out of categorically different components — a separate event
store, a separate workflow engine, a separate durable-execution cluster
— each with its own vocabulary, deployment model, and observability
surface.

The benefits compound. Code maintenance gets easier because the same
type-checked artifact expresses an aggregate, a process manager, and a
v2 workflow; refactoring is safe because durability hangs off named
steps, not source positions. Understanding business workflows gets
easier because the diagram and the code are the same artifact, and the
state machine is legible to engineers and auditors alike. Operating
complex systems gets easier because there is no second cluster to run,
no high-water-mark machinery to debug, no parallel storage path to
correlate, and the transactional step closes a class of distributed-
state bugs by construction.

The honest costs are real and enumerated in §7: Haskell-only, Postgres-
only, steeper formalism than a Decider library, pre-1.0 today, and no
graphical designer. For teams that fit the profile in §8, the trade is
strongly favourable. For teams that don't, one of DBOS, Temporal,
Restate, Inngest, Marten, Eventide, or Camunda is a better answer — and
this document tries to say honestly which one and why.
