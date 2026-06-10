---
id: 63
slug: keiro-dsl-pgmq-workqueue-and-dispatch-nodes
title: "keiro-dsl pgmq workqueue and dispatch nodes"
kind: exec-plan
created_at: 2026-06-10T01:05:27Z
intention: "intention_01ktqdn85xe2btqzr2zghxgrpr"
master_plan: "docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md"
---

# keiro-dsl pgmq workqueue and dispatch nodes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-pgmq` is a small Haskell library in this repository (under `keiro-pgmq/`) that
turns Postgres into a background-job queue. It builds on **PGMQ**, a Postgres extension
that stores a queue as a table `pgmq.q_<name>` of JSON message bodies. A service declares
a typed **`Job`** value — a queue name, a payload codec, and a retry policy — and writes a
plain handler `payload -> Eff es JobOutcome` that decides per message whether the work is
`Done`, should `Retry` after a delay, or is a poison message to send to a **dead-letter
queue** (DLQ, the parking lot for messages that can never succeed). One real service in the
external conformance corpus uses this: **hospital-capacity**'s *reservation-work* queue.

This plan adds two node types to the `keiro-dsl` toolchain — a terse, machine-checkable
notation for keiro services that scaffolds the deterministic boilerplate and leaves the
genuinely behavior-bearing logic as precisely-typed holes a human or agent fills:

- A **`workqueue`** node — the producer/consumer-agnostic *declaration* of one PGMQ job:
  its logical queue name, the **captured physical/DLQ/table names** that name derivation
  produces, its payload field map (camelCase Haskell field → snake_case JSON key), its
  retry policy, and its **disposition table** (which domain failure becomes `Done` /
  `Retry n` / `Dead`).
- A **`dispatch`** node — the *read-model→enqueue* coupling that drives a workqueue: it
  reads rows from a read-model table, fans each row out into zero-or-more work items, dedups
  against already-decided/already-queued work, and enqueues the survivors onto a
  `workqueue`.

After this change a developer can write a `.keiro` spec containing a `workqueue` and a
`dispatch` block, run `keiro-dsl check spec.keiro` to have the validator **reject** a queue
that has no failure policy, a disposition table with a dangerous inversion (a transient
store error routed to the DLQ instead of retried, or a poison/decode payload retried
forever), or a physical-table name that drifts from what name derivation actually produces;
then run `keiro-dsl scaffold spec.keiro --out <dir>` to emit the symbol-free `Job`
declaration, `JobCodec` field map, retry policy, and queue wiring into `-- @generated`
modules, plus typed holes for the two pieces of real logic (the effectful fan-out body and
the raw-SQL dedup predicate), plus a harness that round-trips the codec, asserts the
disposition table is total, and **asserts the captured physical-name fixture matches what
`queueRef` derives**. The observable proof is a captured conformance fixture: the
scaffolded `Generated` modules for *reservation-work* compile, the firewall invariant holds
(no `-- @generated` line contains a keiki symbolic operator), and the harness is green;
mutating the captured physical-name fixture turns a harness test red.

**Caveat recorded up front (a risk, not a footnote):** there is exactly **one** real PGMQ
work-queue dispatch in the whole corpus — hospital-capacity's reservation-work.
incident-command's `ProjectionWorker.hs` is an *event-store projection drainer*, not a PGMQ
queue, so it is **not** a second instance. The generality of these two node types is
therefore **unproven**: every grammar and validator decision below is fitted to a sample of
one. The plan deliberately keeps the notation close to the single real instance and flags
(in Surprises and in the Decision Log) every place where we are guessing at generality, so
a second instance can correct us cheaply rather than us over-fitting now.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (grammar + parser) DONE 2026-06-10: added `NWorkqueue`/`NPgmqDispatch` constructors to `Keiro.Dsl.Grammar`, including the fixture-bearing `derive physical=… dlq=… table=…` lines and the disposition table; extend the parser so a `workqueue`/`dispatch` block round-trips through the pretty-printer.
- [ ] Milestone 1: extend the bijection table (in this plan's Context) with the `workqueue`/`dispatch` → `keiro-pgmq` rows in the same change as the grammar constructors (faithfulness contract).
- [x] Milestone 2 (validator) DONE 2026-06-10 (headline rules): physical-name divergence vs queueRef, the storeFailure/decodeFailure inversions, dlq=on/maxRetries ceiling, and dispatch enqueue resolution. Lower-value rules (dedup-key-binds-to-payload, dlq-off-with-DeadLetter warning) remain. Originally: to `Keiro.Dsl.Validate` — require-a-derivation (+ fixture-divergence check by re-running `queueRef` semantics), require-a-disposition, dangerous-inversion flags, queue-name-divergence across nodes, dedup-key-binds-to-payload-field, `maxRetries ≥ 1` when `dlq=on`, dlq-off-with-DeadLetter-arm warning, and the producer-failure-vs-consumer-JobOutcome separation.
- [ ] Milestone 3 (scaffold): emit the symbol-free `Generated` layer (the `Job` value, the `JobCodec` field map, the `RetryPolicy`, the `queueRef` wiring, the disposition `JobOutcome` mapping) plus `HoleStub` signatures for the fan-out body and the raw-SQL dedup predicate; **never** emit the raw SQL. Confirm the firewall invariant holds.
- [ ] Milestone 4 (harness): emit codec round-trip, disposition-coverage, and the captured-physical-name-fixture-matches-`queueRef` tests.
- [ ] Milestone 5 (conformance): capture the *reservation-work* reference modules under `keiro-dsl/test/fixtures/`, scaffold from a hand-written `reservation-work.keiro`, show the `Generated` modules compile and the harness is green, and show a fixture mutation turns a test red.
- [ ] Record the honest coverage gaps (raw-SQL dedup predicate, fan-out body + its producer-failure arms, trace-header propagation, deliberate-malformed test path, versioned `{v,data}` codec, run cadence) in Surprises and in the scaffold hole comments.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Model PGMQ as **two** node types — `workqueue` (the `Job` declaration) and
  `dispatch` (the read-model→enqueue coupling) — rather than one combined node.
  Rationale: the two map to genuinely different keiro-pgmq surfaces and different failure
  surfaces. A `workqueue` corresponds to `Keiro.PGMQ.Job.Job p` plus its `JobCodec`,
  `RetryPolicy`, and the consumer `JobOutcome` mapping; a `dispatch` corresponds to the
  hand-written producer path in `HospitalCapacity/Integration/ReservationWorkDispatch.hs`
  whose failures are `ReadModelError`/`StoreError`, **not** `JobOutcome`. Conflating them
  would force the producer-failure arms and the consumer-disposition arms into one table,
  which is exactly the confusion the validator must prevent (`ReservationWorkDispatch.hs:30-35`
  vs `Job.hs:79-87`). One queue can be referenced by zero dispatch nodes (a queue fed by a
  consumer elsewhere) or one; keeping them separate makes that a node-reference, not a
  sub-block. Date: 2026-06-10
- Decision: Treat the **physical / DLQ / table** names as **captured fixtures** in the
  grammar (`derive physical=… dlq=… table=…`), not as values the scaffolder recomputes at
  emit time — and have the validator *re-run* `queueRef` semantics to check the fixture has
  not drifted.
  Rationale: `Keiro.PGMQ.Runtime.queueRef` (`Runtime.hs:71-77`) is an **opaque, lossy**
  sanitizer — it lowercases, maps non-`[a-z0-9_]`→`_`, collapses underscore runs, forces a
  leading letter, and **truncates to 43 chars** — so a long or dotted logical name can be
  silently renamed. The real Postgres table is `pgmq.q_<physical>`
  (`ReservationWorkDispatch.hs:183-184`), and that table name is **re-spelled by hand as a
  SQL literal** at the dedup site with nothing linking it to the `queueRef "…"` call at the
  `Job` node (`WorkQueue.hs:99`). Capturing the derived names as fixtures, and failing the
  build when re-deriving diverges from the fixture, is the only way to make that fragile
  hand-coupling a checked invariant. Date: 2026-06-10
- Decision: **Never** emit the raw-SQL dedup predicate; emit it as a typed `HoleStub`
  signature with a comment naming the captured table fixture and the bound payload key.
  Rationale: the dedup predicate (`selectReservationWorkPendingOrDecidedStmt`,
  `ReservationWorkDispatch.hs:172-188`) is an arbitrary `EXISTS … OR … json-path` raw SQL
  statement — exactly the in-body computation the MasterPlan scopes out as an agent-written,
  harness-pinned hole. Emitting it would also breach the firewall principle of keeping
  framework-/SQL-coupled logic out of `-- @generated`. The grammar still *captures* the
  table fixture and the bound key so the validator can check the coupling, but the
  statement body stays a hole. Date: 2026-06-10
- Decision: Keep the notation deliberately close to the single real instance and label every
  generality assumption.
  Rationale: a sample of one (see the prominent caveat in Purpose) cannot justify a general
  schema; over-fitting now is cheaper to correct than a wrong abstraction. Date: 2026-06-10
- Decision: Soft-reuse EP-4's `contract`/envelope-binding machinery for the dedup
  envelope-key↔payload-field binding, but start with a **local** notion of that binding and
  reconcile when EP-4's `contract` block lands.
  Rationale: a pgmq dispatch's dedup key (`message ->> 'reservation_id'`,
  `ReservationWorkDispatch.hs:184`) is a payload-field reference of the same shape EP-4
  binds for inbox/outbox envelopes; depending on EP-4 hard would serialize two parallelizable
  plans. EP-4 is a soft dep in the MasterPlan registry for exactly this reason. Date: 2026-06-10


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### Where this plan sits

This is **EP-5** of the MasterPlan `docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md`.
It **hard-depends** on **EP-1 Foundations**
(`docs/plans/59-keiro-dsl-foundations-grammar-parser-validator-scaffold-and-harness-engine-aggregate-vertical.md`),
which builds the shared `keiro-dsl` engine this plan extends. It **soft-depends** on **EP-4
Integration** (`docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`)
for the `contract`/envelope-binding machinery. Reference those plans only by the paths just
given; everything you need from them is restated below.

`keiro-dsl` does **not exist yet** as a directory — EP-1 creates the `keiro-dsl/` package.
Do not start this plan until EP-1 is Complete. When you do, you are *extending* EP-1's
modules, never replacing them.

### What EP-1 gives you (restated signatures you rely on)

EP-1 creates a new Cabal package `keiro-dsl/` (added to the repo's `cabal.project`) with
these modules and exact signatures. Treat these as fixed contracts:

- `Keiro.Dsl.Grammar` — the abstract syntax tree (AST: the in-memory tree a parser produces
  from text). It defines a top-level `data Spec` aggregating a list of nodes, a `data Node`
  sum type with one constructor per node type (EP-1 ships `Aggregate`; each vertical adds
  its own), and the shared declaration helpers (`IdDecl`, `EnumDecl`, `RuleDecl`, the hole
  types, and an `Expr` sublanguage for value references). **You add `Workqueue` and
  `Dispatch` constructors to `Node` here.**
- `Keiro.Dsl.Parser` — exposes `parseSpec :: Text -> Either ParseError Spec` (a megaparsec
  parser). **You extend it to parse `workqueue`/`dispatch` blocks.**
- `Keiro.Dsl.PrettyPrint` — the inverse of the parser; EP-1 establishes a parse↔print
  round-trip property test. **Your new blocks must round-trip.**
- `Keiro.Dsl.Validate` — exposes the diagnostic type and
  `validateSpec :: Spec -> [Diagnostic]`. A `Diagnostic` carries a severity
  (`Error`/`Warning`), a source location, and a message; `keiro-dsl check` prints them and
  exits non-zero if any is an `Error`. **You add the pgmq rules here.**
- `Keiro.Dsl.Scaffold` — exposes `data ScaffoldModule = ScaffoldModule { modulePath :: FilePath, moduleText :: Text, kind :: ModuleKind }`
  and `data ModuleKind = Generated | HoleStub`. `Generated` modules carry a `-- @generated`
  marker and are **overwritten** on every scaffold; `HoleStub` modules are written only if
  absent (**create-if-absent**), so hand-filled logic is never clobbered. EP-1 ships
  `scaffoldAggregate :: Context -> Aggregate -> [ScaffoldModule]`. **You add a
  `scaffoldWorkqueue`/`scaffoldDispatch`-style emitter.** `Context` is EP-1's record of
  module-root and naming context threaded through every emitter.
- **FIREWALL INVARIANT (EP-1, tested):** no `Generated` module's `moduleText` contains a
  keiki symbolic operator (the `./=`, `lit`, `B.slot`, `B.requireGuard`-style operators of
  the transducer DSL). Every emitter you add must satisfy this. For pgmq this is easy: the
  symbol-free layer is plain record construction; the only thing that *could* breach it (the
  raw-SQL dedup predicate) is a `HoleStub`, not `Generated`.
- `Keiro.Dsl.Harness` — exposes `harnessFor :: Context -> Aggregate -> [ScaffoldModule]`
  emitting harness test modules. **You add a pgmq harness emitter.**
- The CLI (`keiro-dsl/app/Main.hs`) — an optparse-applicative command tree with
  `parse`/`check`/`scaffold`. You add **no** new subcommand; the existing ones gain
  `workqueue`/`dispatch` behavior automatically once `Grammar`/`Validate`/`Scaffold` handle
  the new constructors.

### The keiro-pgmq library (the bijection target) — read these files

Everything the scaffolder emits is a faithful image of `keiro-pgmq`. The package lives at
`keiro-pgmq/src/Keiro/PGMQ/` and has **no README** — only `keiro-pgmq/keiro-pgmq.cabal` and
the source. The three modules:

- `keiro-pgmq/src/Keiro/PGMQ/Runtime.hs` — Layer 1, transport-agnostic plumbing. Owns
  **`QueueRef`** and the **`queueRef`** name derivation.
- `keiro-pgmq/src/Keiro/PGMQ/Codec.hs` — the **`JobCodec p`** payload codec.
- `keiro-pgmq/src/Keiro/PGMQ/Job.hs` — Layer 2, the typed **`Job p`** ergonomics:
  `JobOutcome`, `RetryPolicy`, `enqueue`, `ensureJobQueue`, `jobProcessor`, `runJobWorkers`,
  `runJobOnce`.

The exact shapes you must reproduce (file:line anchors are the source of truth — re-read
them; restated here so this plan is self-contained):

**The `Job p` record** (`Job.hs:113-119`):

```haskell
data Job p = Job
    { jobName  :: !Text          -- shibuya ProcessorId + telemetry label
    , jobQueue :: !QueueRef
    , jobCodec :: !(JobCodec p)
    , jobPolicy :: !RetryPolicy
    }
```

**The payload codec** (`Codec.hs:29-32`): `JobCodec p` is a pair of functions
`encodeJob :: p -> Value` and `decodeJob :: Value -> Either Text p` (PGMQ stores bodies as
aeson `Value`). The real reservation-work payload is a **flat 9-field record** with
**snake_case JSON keys** built by hand (`WorkQueue.hs:64-74` declares the record;
`WorkQueue.hs:125-137` is `reservationWorkItemToValue` with keys `reservation_id`,
`hospital_id`, `command_id`, `patient_acuity`, `required_bed_type`, `source_message_id`,
`expiration_deadline`, `divert_status`, `life_critical_override`; `WorkQueue.hs:328-340` is
the matching parser). The camelCase-Haskell-field → snake_case-JSON-key mapping is a
**convention, not enforced** by the library — so it is **Hole 3 (mapping)** + **Hole 4
(field-source)** and the field map must be captured explicitly in the spec.

**Physical / DLQ / table name derivation** (`queueRef`, `Runtime.hs:71-77`, **Hole 1
derivation, opaque → needs a captured fixture**): given a logical name it
lowercases, replaces every non-`[a-z0-9_]` character with `_`, collapses repeated
underscores (trimming leading/trailing), forces a leading letter, and **truncates the base
to 43 characters** (`maxBaseLength = 43`, `Runtime.hs:81-83`) so the `_dlq` suffix still
fits PGMQ's 47-character ceiling. `physicalName` is `forceQueueName base`; `dlqName` is
`forceQueueName (base <> "_dlq")`. The real Postgres table is **`pgmq.q_<physical>`**
(seen as the raw literal `pgmq.q_hospital_capacity_reservation_work`,
`ReservationWorkDispatch.hs:183-184`). For the real queue the derivation is lossless
(`"hospital_capacity.reservation_work"` → `hospital_capacity_reservation_work`), but the
truncation/collapse can silently rename a longer or messier logical name, which is exactly
why every raw-SQL site that references the table needs the **derived name captured as a
fixture** and checked.

**Retry / disposition** (**Hole 2 disposition**). `RetryPolicy` (`Job.hs:94-98`) is
`{ maxRetries :: Int64, defaultRetryDelay :: RetryDelay, useDeadLetter :: Bool }`. The real
policy is `maxRetries=3`, `defaultRetryDelay=RetryDelay 5` (seconds), `useDeadLetter=True`
(`WorkQueue.hs:101-106`). `wrapHandler` (`Job.hs:174-181`) maps outcomes to shibuya acks:
a payload the codec **rejects** → `AckDeadLetter (InvalidPayload err)`; `Done` → `AckOk`;
`Retry d` → `AckRetry d`; `Dead why` → `AckDeadLetter (PoisonPill why)`. The **domain**
disposition (`reservationWorkFailureOutcome`, `WorkQueue.hs:163-170`) is: store-failure →
`Retry (RetryDelay 5)`; command-rejection → `Dead`; internal decode-failure → `Dead`.
**THE INVERSION the validator must guard:** a *transient* store error must be `Retry`, not
`Dead` (else you lose recoverable work); a *poison/decode* payload must be `Dead`, not
`Retry` (else it redelivers forever, a hot loop). Naming a transient-sounding failure
`DeadLetter`, or a poison/decode failure `Retry`, is the dangerous mistake.

**The read-model→enqueue coupling** (the load-bearing **Hole 5, cross-node coupling**),
`ReservationWorkDispatch.hs`:

1. **Source read model** `accepted_transfer_needs` — `selectLatestAcceptedTransferNeedStmt`
   (`:133-170`) selects the latest accepted transfer need.
2. **Effectful fan-out** — `resolveTransferCandidates accepted` (called at `:81`) turns one
   accepted need into N candidate work items (1→N). This is effectful (it reads the store)
   and its failures are `StoreError`/`ReadModelError`.
3. **Idempotency/dedup key** = `reservation_id`, checked by
   `selectReservationWorkPendingOrDecidedStmt` (`:172-188`) against **both** the
   `transfer_decisions` read-model table **and** the **raw physical pgmq table** via
   `message ->> 'reservation_id'`.
4. **Enqueue** to `reservationWorkJob.jobQueue.physicalName` (`WorkQueue.hs:202-223`,
   `enqueueReservationWorkWithTelemetry`).

**The fragile coupling (Hole 5 + Hole 1 + Hole 4 in one place):** the queue physical name
is defined **once** at the `Job` node as `queueRef "hospital_capacity.reservation_work"`
(`WorkQueue.hs:99`) but **re-spelled by hand** as the SQL literal
`pgmq.q_hospital_capacity_reservation_work` at the dedup site
(`ReservationWorkDispatch.hs:183`) — **nothing links them**. And the JSON key
`'reservation_id'` inside that SQL (`:184`) silently couples to the payload key declared at
`WorkQueue.hs:127`. These are precisely the drift hazards the captured fixtures + validator
checks exist to catch.

**Two distinct disposition surfaces — do NOT conflate:** the **producer-failure** surface
is `ReservationWorkDispatchFailure` (`ReservationWorkDispatch.hs:30-35`:
`…StoreFailed`/`…ReadModelFailed`/`…QueueFailed`/`…NoAcceptedTransferNeed`) — what can go
wrong while *enqueuing*. The **consumer** surface is `JobOutcome` (`Job.hs:79-87`:
`Done`/`Retry`/`Dead`) — what the handler decides per message. These belong to the
`dispatch` node and the `workqueue` node respectively, and the validator must keep them
apart.

### The eight hole-kinds, instantiated for pgmq

The MasterPlan's coverage audit found the non-derivable remainder of any keiro feature
collapses into a closed set of **eight hole-kinds**. For pgmq they land as:

1. **Derivation** — the opaque queue physical-table name → a **captured fixture**
   (`derive physical=… dlq=… table=…`).
2. **Disposition** — the `AckOk | Retry n | DeadLetter r` table, with the two inversions
   flagged.
3. **Mapping** — the payload record ↔ JSON object (`reservationWorkItemToValue`/parser).
4. **Field-source** — each JSON key's source field (camel→snake is convention, not enforced).
5. **Cross-node coupling** — queue name *define-once* at the workqueue; the
   read-model→enqueue coupling at the dispatch.
6. **Decode strictness** — whether an unknown/missing field is a hard decode failure (the
   real parser uses `.:`, which is strict/required).
7. **Optionality** — which fields are required vs optional in the payload.
8. **Runtime config** — poll batch size / pool size (e.g. `runJobOnce 1`,
   `PoolConfig.size 4` at `WorkQueue.hs:185`) — **delegated** (a runner/runtime concern, not
   spec-expressed; see Coverage Gaps).

**Cross-cutting rule (inherited from EP-1):** time is **injected, not sampled** — a retry
delay is a literal in the spec (`RetryDelay 5`), never a clock read; the scaffolder never
emits a `getCurrentTime`-style call into a `Generated` module.

### The bijection table rows (add in the same change as the grammar)

The MasterPlan's faithfulness contract requires that a new node type extend the bijection
table together with `Grammar`. The two rows this plan adds:

| DSL node | keiro primitive | Anchor |
|----------|-----------------|--------|
| `workqueue` | `Keiro.PGMQ.Job.Job p` + `JobCodec` + `RetryPolicy` + consumer `JobOutcome` | `Job.hs:113-119`, `Codec.hs:29-32`, `Job.hs:94-98`, `Job.hs:79-87` |
| `dispatch` | read-model→enqueue producer path (source read model + key + effectful fan-out + dedup + enqueue-to a workqueue) | `ReservationWorkDispatch.hs:46-188`, `WorkQueue.hs:202-223` |

### Proposed notation (refine into the grammar during Milestone 1)

A `workqueue` node bundles the `Job` (queue logical name + captured physical/DLQ/table
fixtures, payload field map, retry policy, disposition table). A `dispatch` node expresses
read-model→enqueue (source read model + key, fan-out, enqueue-to a workqueue, dedup key with
seen-in-read-model + seen-in-queue). The names below are transcribed from the **real**
reservation-work instance, and the `derive` line is marked *captured, not recomputed*:

```text
workqueue reservation_work {
  queue   logical = "hospital_capacity.reservation_work"
  # captured from queueRef — NOT recomputed at scaffold time; validator re-derives to check
  derive  physical = "hospital_capacity_reservation_work"
          dlq      = "hospital_capacity_reservation_work_dlq"
          table    = "pgmq.q_hospital_capacity_reservation_work"

  payload ReservationWorkItem {
    reservationId        -> "reservation_id"        text required
    hospitalId           -> "hospital_id"           text required
    commandId            -> "command_id"            text required
    patientAcuity        -> "patient_acuity"        text required
    requiredBedType      -> "required_bed_type"     text required
    sourceMessageId      -> "source_message_id"     text required
    expirationDeadline   -> "expiration_deadline"   text required
    divertStatus         -> "divert_status"         text required
    lifeCriticalOverride -> "life_critical_override" bool required
  }

  retry   maxRetries = 3  delay = 5s  dlq = on

  # consumer JobOutcome disposition — the domain-failure → outcome table
  disposition {
    storeFailure     -> retry 5s        # transient: MUST retry, not dead-letter
    commandRejected  -> deadLetter      # terminal
    decodeFailure    -> deadLetter      # poison: MUST dead-letter, not retry
    onCodecReject    -> deadLetter      # library auto-routes a codec-reject to DLQ
  }
}

dispatch reservation_work_dispatch {
  source  readModel = accepted_transfer_needs   key = reservationId
  fanout  body = resolveTransferCandidates      # effectful 1→N — HOLE (agent-written)
  dedup   key = reservationId
          seenIn readModel = transfer_decisions field = reservation_id
          seenIn queue     = reservation_work    field = reservation_id   # raw-SQL — HOLE
  enqueue to = reservation_work
}
```

This notation is a *proposal* to refine, not a fixed surface; the only hard requirements are
that it carry the captured derivation fixtures, the disposition table separate from the
producer-failure arms, and the two `seenIn` couplings that bind the dedup key to a payload
field. Keep it close to this single instance (see the prominent caveat).


## Plan of Work

The work is five milestones. Each is independently verifiable. After EP-1 is Complete, the
five can proceed in order; Milestones 1–4 build the engine extension and Milestone 5 proves
it against the one real corpus instance. All paths below are repository-relative under
`keiro-dsl/`, the package EP-1 creates.

### Milestone 1 — Grammar + parser for `workqueue` and `dispatch`

**Scope.** Add two constructors to EP-1's `Node` sum type in
`keiro-dsl/src/Keiro/Dsl/Grammar.hs` and teach the parser and pretty-printer the two new
blocks. **What exists at the end:** a `.keiro` file containing a `workqueue` and a `dispatch`
block parses to a `Spec`, and re-printing it round-trips. The bijection table gains its two
rows in the same commit.

Concretely:

- In `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add `Workqueue WorkqueueDecl` and
  `Dispatch DispatchDecl` to the `Node` sum. Define `WorkqueueDecl` carrying: the node name;
  a `QueueDecl { logical :: Text }`; a `DeriveDecl { physical :: Text, dlq :: Text, table :: Text }`
  (the captured fixtures — model these as plain captured `Text`, **not** as something the
  scaffolder computes); a `PayloadDecl` reusing EP-1's field/id declaration helpers, where
  each field row is `(haskellField :: Text, jsonKey :: Text, FieldType, Optionality)`
  (covers Holes 3, 4, 6, 7); a `RetryDecl { maxRetries :: Int64, delay :: RetryDelay, dlq :: Bool }`;
  and a `DispositionDecl` — a list of `(FailureName, Outcome)` where
  `data Outcome = OutAckOk | OutRetry RetryDelay | OutDeadLetter (Maybe Text)` and one
  reserved `onCodecReject` arm. Reuse EP-1's `RetryDelay`/`Expr` types if present; otherwise
  add a minimal `RetryDelay` here mirroring `Shibuya.Core.Ack.RetryDelay` (a `Word`/`Int`
  seconds wrapper). Define `DispatchDecl` carrying: the node name; a
  `SourceDecl { readModel :: Text, key :: Text }`; a `FanoutDecl { body :: Text }` (the hole
  identifier — the body itself is agent-written); a `DedupDecl { key :: Text, seenInReadModel :: SeenIn, seenInQueue :: SeenIn }`
  where `data SeenIn = SeenIn { table :: Text, field :: Text }`; and an
  `EnqueueDecl { toWorkqueue :: Text }` naming a `workqueue` node.
- In `keiro-dsl/src/Keiro/Dsl/Parser.hs`, add `workqueueP` and `dispatchP` block parsers and
  wire them into the top-level node parser EP-1 exposes. Follow EP-1's lexer conventions
  (whatever it uses for identifiers, string literals, and block delimiters — read
  `Keiro.Dsl.Parser` first and match it exactly).
- In `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs`, add the inverse printers so the round-trip
  property test EP-1 established also covers the two new blocks.
- Append the two bijection-table rows (above) to this plan's Context **in the same commit**
  (the faithfulness contract).

**Acceptance.** `cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation-work/reservation-work.keiro`
(once the fixture exists in Milestone 5; until then a small inline test spec) succeeds and
prints the parsed `Spec`; the round-trip property test passes.

### Milestone 2 — Validator rules

**Scope.** Add the pgmq rules to `keiro-dsl/src/Keiro/Dsl/Validate.hs`. **What exists at the
end:** `keiro-dsl check` rejects malformed pgmq specs with specific diagnostics, and accepts
the real reservation-work spec. Each rule below produces an `Error` unless marked `Warning`.

The rules (every one restated as behavior):

1. **Require a derivation.** Every `workqueue` **must** declare `derive physical=…`. If the
   logical name contains any character the sanitizer rewrites (a dot, an uppercase letter, an
   underscore run, or length > 43 — i.e. anything that makes derivation lossy), the
   `physical`, `dlq`, and `table` fixtures **must** be present. *Error* if missing.
2. **Fixture-divergence check.** Re-run `queueRef` semantics **inside the validator** over
   the logical name and assert the result equals the captured `physical`/`dlq` fixtures, and
   that `table == "pgmq.q_" <> physical`. **Error on divergence.** Implement the sanitizer
   as a small pure function in `Validate` that mirrors `Runtime.hs:85-113` exactly
   (lowercase → map non-`[a-z0-9_]`→`_` → collapse underscores → ensure leading letter →
   take 43); do not import `keiro-pgmq` (keep `keiro-dsl` dependency-light), but pin the
   mirror with a harness test in Milestone 4 that compares it to the real `queueRef`.
3. **Require a disposition.** A `workqueue` with no disposition table is an *Error*. When
   `dlq = on`, the disposition **must** include an on-codec-reject arm **and** at least one
   terminal (`deadLetter`) arm; reject a queue with no failure policy.
4. **Flag dangerous inversions.** *Error* (or a strong *Warning* — choose `Error`, see
   Decision Log if you change it) when a failure whose name signals transience
   (`store`, `timeout`, `transient`, `unavailable`, `retry`-able by convention) maps to
   `deadLetter`; and when a failure whose name signals poison/permanence
   (`decode`, `poison`, `invalid`, `reject`, `malformed`) maps to `retry`. The names are a
   heuristic over a sample of one — emit the diagnostic with the matched keyword so a human
   can confirm.
5. **Queue-name divergence across nodes.** The `physical`/`table` at a `workqueue` **must**
   equal every `dispatch` that `enqueue to`s it and every `seenIn queue` fixture that
   references it. *Warning* when a raw-SQL `pgmq.q_<x>` `table` fixture's `<x>` ≠ the derived
   `physical` (this is the exact `ReservationWorkDispatch.hs:183` ↔ `WorkQueue.hs:99` drift
   hazard).
6. **Bind the dedup envelope key to a payload field.** A `dispatch`'s `dedup key` and each
   `seenIn … field` **must** name a JSON key present in the target `workqueue`'s payload map
   (Hole 4 coupling). *Error* if the field is absent. (This is where EP-4's `contract`
   binding will plug in once it lands; until then this local check stands.)
7. **`maxRetries ≥ 1` when `dlq = on`.** *Error* if `dlq = on` and `maxRetries < 1`
   (`maxRetries` is `Int64`; the real value is 3, `Job.hs:95`). **Warning** if `dlq = off`
   while any disposition arm is `deadLetter` (an unreachable dead-letter route).
8. **Separate producer-failure arms from consumer JobOutcome arms.** The disposition table
   lives only on the `workqueue` (consumer `JobOutcome`). If a `dispatch` block ever grows a
   failure-mapping sub-block, it must be a *distinct* producer-failure surface
   (`ReadModelError`/`StoreError`/`QueueFailed`), never reusing the `JobOutcome` outcomes.
   For now, *Error* if a `dispatch` block contains `retry`/`deadLetter`/`ackOk` outcome
   tokens (they belong to the workqueue).

**Acceptance.** A small suite of negative fixtures (a queue with no `derive`, a divergent
`physical`, a `storeFailure -> deadLetter` inversion, a `dlq = off` + `deadLetter` arm, a
dedup key absent from the payload) each yields the expected `Error`/`Warning`; the real
reservation-work spec yields **zero** diagnostics.

### Milestone 3 — Scaffold (symbol-free `Generated` + typed `HoleStub`s)

**Scope.** Add the pgmq emitter to `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`. **What exists at
the end:** `keiro-dsl scaffold` writes `Generated` modules containing the `Job` value, the
`JobCodec` field map, the `RetryPolicy`, the `queueRef` wiring, and the disposition
`JobOutcome` mapping; and `HoleStub` modules containing typed signatures for the effectful
fan-out body and the raw-SQL dedup predicate. The firewall invariant holds.

Emit, into a `Generated` module (overwrite, carries `-- @generated`):

- The payload record (`data ReservationWorkItem = ReservationWorkItem { … }`, the 9 fields
  from the payload map, `Job.hs`/`WorkQueue.hs:64-74` shapes).
- `reservationWorkItemToValue`/`…FromValue` built mechanically from the field map
  (snake_case keys, `.:`/`.=`), reproducing `WorkQueue.hs:125-142,328-340`.
- The `reservationWorkJobCodec :: JobCodec ReservationWorkItem` (`WorkQueue.hs:112-117`) — a
  literal `JobCodec`, **not** the versioned `keiroJobCodec` (see Coverage Gaps).
- The `reservationWorkJob :: Job ReservationWorkItem` value with
  `jobQueue = queueRef "<logical>"` and the `RetryPolicy` from the `retry` line
  (`WorkQueue.hs:95-107`).
- The disposition → `JobOutcome` mapping (`reservationWorkFailureOutcome`,
  `WorkQueue.hs:163-170`) as a `case` over the failure type, each arm the literal outcome
  from the disposition table.

Emit, into a `HoleStub` module (create-if-absent, **no** `-- @generated`):

- A typed signature **only** for the effectful fan-out body, e.g.
  `resolveTransferCandidates :: AcceptedTransferNeed -> Eff es (Either ReadModelError [Candidate])`,
  with a comment: *"agent-written: 1→N fan-out; failures are ReadModelError/StoreError
  (producer surface), NOT JobOutcome."*
- A typed signature **only** for the raw-SQL dedup predicate, e.g.
  `selectReservationWorkPendingOrDecided :: Statement Text Bool`, with a comment naming the
  **captured table fixture** (`pgmq.q_hospital_capacity_reservation_work`) and the **bound
  payload key** (`reservation_id`), and an explicit *"DO NOT regenerate; raw SQL is
  hand-owned"*. **Never emit the SQL string itself.**

The firewall invariant is satisfied because the `Generated` layer is plain record/`Job`
construction with no keiki symbolic operator, and the only SQL/framework-coupled piece is a
`HoleStub`.

**Acceptance.** `keiro-dsl scaffold` over the reservation-work spec writes the modules; the
EP-1 firewall-invariant test (no `Generated` line contains a keiki symbolic operator) passes
over the new emitter; re-running `scaffold` overwrites `Generated` but leaves a hand-edited
`HoleStub` untouched.

### Milestone 4 — Harness

**Scope.** Add the pgmq harness emitter to `keiro-dsl/src/Keiro/Dsl/Harness.hs`. **What
exists at the end:** the scaffolded harness module contains three kinds of test.

- **Codec round-trip.** For a generated/sample payload `p`,
  `decodeJob c (encodeJob c p) == Right p`, and a golden wire fixture (the exact JSON object
  with snake_case keys) decodes to the expected record (pins Holes 3/4/6/7).
- **Disposition coverage.** A test asserting the disposition mapping is **total** over the
  domain failure type and that each arm produces the spec's outcome — including a test that
  a transient (`storeFailure`) arm is `Retry` and a poison (`decodeFailure`) arm is `Dead`
  (pins Hole 2 and the inversion guard at runtime, not just at check time).
- **Captured-physical-name fixture matches `queueRef`.** A test that imports the **real**
  `Keiro.PGMQ.Runtime.queueRef` (the harness module can depend on `keiro-pgmq`, unlike the
  validator's mirror) and asserts
  `queueRef "<logical>" == QueueRef "<logical>" "<physical-fixture>" "<dlq-fixture>"` and
  `"pgmq.q_" <> physical == "<table-fixture>"`. This is the test that turns **red** if the
  captured fixture is mutated — the headline acceptance signal.

**Acceptance.** The harness compiles and is green for the real reservation-work fixture;
mutating the captured `physical` fixture (e.g. dropping a character) turns the
`queueRef`-match test red.

### Milestone 5 — Conformance against reservation-work

**Scope.** Capture the real reservation-work reference modules read-only under
`keiro-dsl/test/fixtures/reservation-work/`, write the canonical `reservation-work.keiro`,
scaffold from it, and prove end-to-end. **What exists at the end:** a conformance fixture
demonstrating the whole loop on the one real instance.

- Capture `keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/WorkQueue.hs`
  and `.../Integration/ReservationWorkDispatch.hs` into
  `keiro-dsl/test/fixtures/reservation-work/reference/` (read-only reference, per EP-1's
  fixture convention).
- Write `keiro-dsl/test/fixtures/reservation-work/reservation-work.keiro` (the notation
  above).
- Scaffold it; diff the `Generated` payload/codec/`Job`/disposition modules against the
  captured reference to confirm the deterministic layer matches (modulo the holes).
- Fill the two holes (fan-out body, dedup predicate) by copying the reference bodies into
  the `HoleStub` modules; build; run the harness.

**Acceptance.** `cabal build` of the scaffolded `Generated` modules succeeds; the harness is
green; the firewall test passes; mutating the captured physical-name fixture turns a harness
test red. Record in Outcomes which parts of the reference were reproduced by `Generated` and
which were holes.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/keiro` unless noted.
These steps assume EP-1 is Complete (the `keiro-dsl/` package exists and builds). If
`keiro-dsl/` is absent, stop and finish EP-1 first.

Confirm the engine builds before extending it:

```bash
cabal build keiro-dsl
```

After Milestone 1 (grammar + parser), parse a spec and confirm round-trip:

```bash
cabal run keiro-dsl -- parse keiro-dsl/test/fixtures/reservation-work/reservation-work.keiro
```

Expected (shape, not exact): a pretty-printed `Spec` echoing the `workqueue reservation_work`
and `dispatch reservation_work_dispatch` blocks. The round-trip property test runs under:

```bash
cabal test keiro-dsl --test-options='--match "round-trip"'
```

After Milestone 2 (validator), check the real spec and a negative fixture:

```bash
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-work/reservation-work.keiro
cabal run keiro-dsl -- check keiro-dsl/test/fixtures/reservation-work/negative/divergent-physical.keiro
```

Expected: the first prints no diagnostics and exits 0; the second prints an `Error` naming
the divergence between the captured `physical` fixture and what `queueRef` derives, and exits
non-zero. Sample expected text:

```text
error: keiro-dsl/test/fixtures/reservation-work/negative/divergent-physical.keiro
  workqueue reservation_work: captured physical "hospital_capacity_reservation_wor"
  diverges from queueRef("hospital_capacity.reservation_work") =
  "hospital_capacity_reservation_work"
```

After Milestone 3 (scaffold), emit modules into a scratch output directory and inspect:

```bash
cabal run keiro-dsl -- scaffold keiro-dsl/test/fixtures/reservation-work/reservation-work.keiro --out /tmp/rw-scaffold
ls -R /tmp/rw-scaffold
```

Expected: `Generated` modules (payload record, codec, `Job`, disposition) carrying a
`-- @generated` first line, and `HoleStub` modules for the fan-out body and dedup predicate
**without** a `-- @generated` line and **without** any raw SQL. Verify the firewall and the
no-SQL-in-Generated properties:

```bash
grep -rl '@generated' /tmp/rw-scaffold | xargs grep -nE 'pgmq\.q_|SELECT|EXISTS' || echo "OK: no raw SQL in Generated"
```

After Milestone 4 (harness) and Milestone 5 (conformance), build and test the scaffolded
fixture and prove the mutation signal:

```bash
cabal test keiro-dsl --test-options='--match "reservation-work"'
```

Then mutate the captured physical-name fixture and confirm a test fails:

```bash
# temporarily shorten the captured physical fixture, re-run, expect a red queueRef-match test
cabal test keiro-dsl --test-options='--match "physical-name"'
# restore the fixture afterwards
```


## Validation and Acceptance

The change is effective — beyond compilation — when all of the following hold on the one
real corpus instance:

- **Check rejects what it must.** Each negative fixture under
  `keiro-dsl/test/fixtures/reservation-work/negative/` produces exactly the intended
  diagnostic: a missing `derive` → require-a-derivation `Error`; a one-character-short
  `physical` → fixture-divergence `Error`; `storeFailure -> deadLetter` → dangerous-inversion
  diagnostic naming the matched keyword; `dlq = off` with a `deadLetter` arm → unreachable-DLQ
  `Warning`; a dedup `key` absent from the payload map → bind-to-payload-field `Error`; a
  `dispatch` block containing a `retry` token → producer/consumer-conflation `Error`. The
  positive reservation-work spec produces **zero** diagnostics.
- **Scaffold is faithful and firewalled.** The `Generated` payload/codec/`Job`/disposition
  modules match the captured reference (modulo holes) and compile; no `Generated` line
  contains a keiki symbolic operator **or** raw SQL; the dedup predicate and fan-out body are
  `HoleStub`s whose comments name the captured table fixture and bound payload key.
- **Harness proves behavior.** Codec round-trip and golden-wire tests pass; the disposition
  table is total and the transient/poison arms behave correctly; the
  captured-physical-name-matches-`queueRef` test passes — and **fails** when the fixture is
  mutated. This last point is the headline behavioral signal that the captured-fixture
  discipline actually guards the `WorkQueue.hs:99` ↔ `ReservationWorkDispatch.hs:183` drift.
- **End-to-end loop.** After filling the two holes from the reference bodies,
  `cabal build` of the scaffolded modules succeeds and `cabal test keiro-dsl` is green.


## Idempotence and Recovery

All steps are safe to repeat. `cabal build`/`cabal test`/`keiro-dsl parse`/`check` are
read-only or build-only. `keiro-dsl scaffold` is idempotent **by construction**: `Generated`
modules are overwritten every run (so re-scaffolding is a no-op against unchanged input), and
`HoleStub` modules are written only when absent (create-if-absent), so a re-scaffold never
clobbers a hand-filled hole. Scaffold into a scratch directory (`/tmp/rw-scaffold`) while
iterating to keep the working tree clean.

The captured reference modules under `keiro-dsl/test/fixtures/reservation-work/reference/`
are **read-only copies** of external corpus files — never edit them in place; if the corpus
changes, re-capture. The fixture-mutation step in Concrete Steps is intentionally temporary:
restore the fixture (via `git checkout`) immediately after observing the red test. Because
`keiro-dsl` is a new, additive package, nothing here touches or migrates any existing keiro
or keiro-pgmq code, so there is no destructive path to roll back.


## Interfaces and Dependencies

**Libraries/packages.** This plan adds **no** new external dependency to `keiro-dsl` beyond
what EP-1 already pulls in (megaparsec for the parser, prettyprinter for the printer,
optparse-applicative for the CLI). The validator's `queueRef` mirror is a hand-written pure
function (no dependency on `keiro-pgmq`) so the checker stays light; the **harness** test
module, by contrast, **depends on `keiro-pgmq`** so it can call the real
`Keiro.PGMQ.Runtime.queueRef` and pin the mirror against it. Add `keiro-pgmq` to the
`keiro-dsl` **test** stanza (not the library stanza) in `keiro-dsl/keiro-dsl.cabal`.

**Shared engine extensions (the contracts that must exist at the end of each milestone).**

- End of M1 — `Keiro.Dsl.Grammar` exports `Workqueue WorkqueueDecl` and `Dispatch DispatchDecl`
  constructors on `Node`, plus the records `WorkqueueDecl`, `QueueDecl`, `DeriveDecl`,
  `PayloadDecl`, `RetryDecl`, `DispositionDecl`, `Outcome`, `DispatchDecl`, `SourceDecl`,
  `FanoutDecl`, `DedupDecl`, `SeenIn`, `EnqueueDecl`. `Keiro.Dsl.Parser.parseSpec` accepts
  the two blocks; `Keiro.Dsl.PrettyPrint` round-trips them.
- End of M2 — `Keiro.Dsl.Validate.validateSpec :: Spec -> [Diagnostic]` emits the eight pgmq
  rules above, including a pure mirror of `queueRef` for the fixture-divergence check.
- End of M3 — `Keiro.Dsl.Scaffold` exposes a pgmq emitter of type
  `Context -> WorkqueueDecl -> [ScaffoldModule]` (and a dispatch counterpart) returning
  `Generated` modules for the symbol-free layer and `HoleStub` modules for the fan-out body
  and dedup predicate, satisfying the firewall invariant `ModuleKind = Generated ⇒ no keiki
  symbolic operator and no raw SQL`.
- End of M4 — `Keiro.Dsl.Harness` exposes a pgmq harness emitter returning the codec
  round-trip, disposition-coverage, and `queueRef`-fixture-match test modules.
- End of M5 — `keiro-dsl/test/fixtures/reservation-work/` holds the `.keiro`, the read-only
  reference modules, and the negative fixtures; `cabal test keiro-dsl` is green.

**Soft EP-4 reuse.** The dedup envelope-key↔payload-field binding (validator rule 6) is the
same shape EP-4 (`docs/plans/62-keiro-dsl-integration-nodes-inbox-outbox-kafka-and-contract.md`)
defines for inbox/outbox envelope bindings via its `contract` block. Start with the **local**
notion implemented in rule 6; when EP-4's `contract` lands, replace the local payload-field
lookup with a `contract` reference and a cross-node binding check, keeping the same
diagnostics. This is a soft dependency: this plan is fully implementable and testable without
EP-4.

**File:line anchors (the source of truth for every emitted shape).**
`Job p` record — `keiro-pgmq/src/Keiro/PGMQ/Job.hs:113-119`.
`JobOutcome` — `Job.hs:79-87`. `RetryPolicy` — `Job.hs:94-98`. `wrapHandler` outcome→ack —
`Job.hs:174-181`. `JobCodec` — `keiro-pgmq/src/Keiro/PGMQ/Codec.hs:29-32`; versioned
`keiroJobCodec` (deliberately *not* used) — `Codec.hs:50-63`. `queueRef` derivation —
`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs:71-77`; `maxBaseLength = 43` — `Runtime.hs:81-83`;
sanitizer internals to mirror — `Runtime.hs:85-113`; `QueueRef` record — `Runtime.hs:51-58`.
Real `Job`/policy — `keiro-runtime-jitsurei/services/hospital-capacity/src/HospitalCapacity/Reservation/WorkQueue.hs:95-107`;
payload record — `WorkQueue.hs:64-74`; to/from JSON — `WorkQueue.hs:125-142,328-340`; domain
disposition — `WorkQueue.hs:163-170`; enqueue path — `WorkQueue.hs:202-223`. Read-model→enqueue
coupling — `.../Integration/ReservationWorkDispatch.hs`: producer-failure surface `:30-35`;
fan-out call `:81`; source read-model statement `:133-170`; raw-SQL dedup predicate (and the
hand-spelled `pgmq.q_…` literal + `message ->> 'reservation_id'`) `:172-188`.


## Coverage Gaps (recorded honestly)

These are deliberately **not** expressible in the notation and are left as agent-written,
harness-pinned holes or as out-of-scope runner concerns. Recorded so a future contributor (or
a second corpus instance) knows what was punted and why:

- **The raw-SQL dedup predicate.** `selectReservationWorkPendingOrDecidedStmt`
  (`ReservationWorkDispatch.hs:172-188`) is an arbitrary `EXISTS … OR … json-path` statement.
  The spec captures the table fixture and bound key for checking, but the SQL body is a
  `HoleStub`. Not expressible.
- **The effectful fan-out body and its producer-failure arms.** `resolveTransferCandidates`
  (the 1→N fan-out, `:81`) and its `ReadModelError`/`StoreError` handling are agent-written
  holes; only the *coupling* (source read model + key + enqueue-to) is in the spec.
- **Trace-header propagation on enqueue.** The real producer uses `sendMessageWithHeaders`
  with W3C `traceparent`/`tracestate` (`WorkQueue.hs:202-238`) rather than the plain
  `enqueue` (`Job.hs:122-129`). The spec scaffolds the plain enqueue; trace-header injection
  is a telemetry concern left to the hole.
- **The deliberate-malformed test path.** `enqueueMalformedReservationWork`
  (`WorkQueue.hs:240-266`) sends a knowingly invalid body to exercise the DLQ. This is a test
  affordance, not a spec construct.
- **The versioned `{v,data}` codec with upcasters.** The real `Job` uses a literal `JobCodec`
  (`WorkQueue.hs:112-117`), so the scaffolder emits a literal codec; `keiroJobCodec`'s
  versioned envelope + upcaster chain (`Codec.hs:50-63`) is EP-2's evolution concern, not this
  plan's.
- **Run cadence.** `runJobOnce` (one-shot drain, `Job.hs:215-230`, the hospital-capacity
  cadence) vs `runJobWorkers` (continuous supervised, `Job.hs:200-208`, the rei cadence), and
  poll batch / pool sizing (Hole 8 runtime config, `runJobOnce 1`, `PoolConfig.size 4` at
  `WorkQueue.hs:185`) are runner/runtime concerns — delegated, possibly a separate
  worker/runner node in a later plan.
- **Generality.** With a single corpus instance, every grammar and validator choice is fitted
  to reservation-work. Treat the notation as provisional until a second PGMQ work-queue
  appears.
