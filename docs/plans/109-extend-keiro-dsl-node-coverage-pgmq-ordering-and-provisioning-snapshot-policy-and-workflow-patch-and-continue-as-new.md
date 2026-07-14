---
id: 109
slug: extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new
title: "Extend keiro-dsl node coverage: pgmq ordering and provisioning, snapshot policy, and workflow patch and continue-as-new"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Extend keiro-dsl node coverage: pgmq ordering and provisioning, snapshot policy, and workflow patch and continue-as-new

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The keiro runtime grew three authoring-relevant capabilities that the `.keiro` notation
cannot express today, so a spec author is forced to smuggle these decisions into hand
code where the toolchain cannot check, pin, or diff them:

1. **pgmq ordering and provisioning.** `Keiro.PGMQ.Job` supports FIFO delivery via
   message groups (`JobOrdering`, `enqueueToGroup`) and three queue storage shapes
   (`QueueProvision`: standard, unlogged, partitioned) plus a FIFO index. A workqueue's
   ordering guarantee and its storage durability class are semantic contracts of the
   queue — the kind of decision the DSL exists to make explicit — yet the `workqueue`
   node has no syntax for them, so every scaffolded queue is silently unordered and
   standard.
2. **Snapshot policy on aggregates.** `Keiro.EventStream` carries a `SnapshotPolicy`
   and a `StateCodec` (version + shape hash) per stream, and (post keiro MasterPlan 14,
   EP-98) construction rejects incoherent combinations. The scaffolder hardcodes
   `snapshotPolicy = Never, stateCodec = Nothing`, so a spec author cannot ask for
   snapshots at all.
3. **Workflow evolution.** `Keiro.Workflow` ships `patch` (guarded old/new branching
   for in-flight instances, EP-49) and `continueAsNew` (journal rotation for unbounded
   workflows, EP-48) — the runtime's *sanctioned* safe-evolution mechanisms — but the
   workflow body grammar has only step/await/sleep/child, so safe evolution is
   unexpressible in the spec and would even be misclassified by the differ once the
   differ learns to see workflow bodies.

After this plan, an author can write `ordering fifo-throughput` with a `group key`
derivation and `provision unlogged` on a workqueue, `snapshot every 100` with a
captured state-codec fixture on an aggregate, and `patch`/`continueAsNew` items in a
workflow body — and see each one parse, round-trip, validate (with the new dangerous-
default rules, e.g. a durability warning on unlogged queues), lower into generated code
compiled against the live runtime, and get pinned by the conformance suites. The plan
also records three scoping decisions (intake `dedupe-only` persistence: **in**, small;
delegated-idempotence intake: **out**, owned by docs/plans/83; sharding/consumer-group
clauses: **out**, deployment-scoped) so future audits find the reasoning, not a gap.

Only the `keiro-dsl` package, its tests, and the authoring-skill docs under
`agents/skills/keiro-dsl-authoring/` change. No runtime package (`keiro`, `keiro-core`,
`keiro-pgmq`, `keiro-migrations`, `keiro-test-support`) is touched.


## Progress

- [x] (2026-07-13T23:59:41Z) M1: `workqueue` ordering / provisioning / group-key — grammar, parser,
      pretty-printer, validator rules (incl. the unlogged durability warning and the
      group-key-iff-FIFO rule), fixtures, unit pins.
- [x] (2026-07-13T23:59:41Z) M1: `workqueue` scaffold lowering (`jobOrdering`, `queueProvision`,
      `jobTuningFor`, `groupKeyFor`) + regenerated committed conformance copies +
      extended `conformance-queue-runtime` assertions + NOTATION.md snippet.
- [ ] M2: aggregate `snapshot` clause — grammar, parser, pretty-printer, validator
      rules (N >= 1, codec fixture required with policy), fixtures, unit pins.
- [ ] M2: snapshot scaffold lowering (aeson derivations on Domain, `defaultStateCodec`
      in EventStream, fixture export) + new `conformance-snapshot` suite proving
      `mkEventStreamOrThrow` accepts the stream and the captured shape hash matches the
      live `regFileShapeHash` + NOTATION.md snippet.
- [ ] M3: workflow `patch` / `continueAsNew` body items — grammar, parser,
      pretty-printer, validator rules (unique patch ids, terminal-only continueAsNew),
      fixtures, unit pins.
- [ ] M3: workflow harness lowering (facts tags, `declaredPatches` /
      `declaredPatchStepNames` / `withDeclaredPatches` over the live runtime) +
      extended `conformance-workflow-runtime` / `conformance-workflow-full` +
      NOTATION.md snippet.
- [ ] M4: intake `persist` clause (grammar through conformance) + Decision Log entries
      for the E8 scope decisions + differ-integration expectations recorded against
      docs/plans/103.
- [ ] Final: full `cabal test` sweep of the keiro-dsl suites green; Outcomes &
      Retrospective written.


## Surprises & Discoveries

- The workflow "scaffold" today is two *harness* modules, not a domain scaffold: the
  CLI (`keiro-dsl/app/Main.hs`, the `wfMods` binding in the `Scaffold` branch) emits
  only `harnessWorkflow ctx wf` for `NWorkflow` nodes, which produces
  `WorkflowFacts.hs` and `WorkflowRuntime.hs` (both `kind = Generated`). There is no
  `scaffoldWorkflow`, no `Domain`-style module, and no `HoleStub` for workflows — the
  filled workflow body is entirely hand code. This plan extends the two harness
  modules; it does not invent a workflow domain scaffold.
- `Keiro.EventStream.Validate` (keiro-core) already carries both EP-98 guards this plan
  leans on: `snapshotWarnings` (a non-`Never` policy with `stateCodec = Nothing` fails
  construction) and `initialSnapshotEncodeWarnings` (the codec must be able to encode
  the initial state/registers, catching `uninit:` register thunks). Verified in the
  working tree at `keiro-core/src/Keiro/EventStream/Validate.hs`.
- keiki's `regFileShapeHash` renders *module-qualified* type names into the hash
  (`Keiki.Shape.renderStableTypeRep` uses `tyConModule <> "." <> tyConName`), and the
  generated module path depends on scaffold placement (`--module-root`, `--collocate`).
  The keiro-dsl library depends only on base/containers/megaparsec/parser-combinators/
  prettyprinter/text — it cannot re-derive the hash at `check` time. Hence the
  shape hash is a *captured fixture* verified by the conformance suite against the live
  runtime, not by the validator (see Decision Log).
- The authored baseline command `cabal build keiro-dsl` became ambiguous after the
  package exposed both a library and an executable with that component name. The
  qualified command `cabal build lib:keiro-dsl` is green, and the actual pre-M1 unit
  baseline is 181 examples rather than the plan's historical 58. M1 raises it to 184.
- `queueProvisionConfigs` returns `Pgmq.Config.QueueConfig`, whose source belongs to
  the registered `shinzui/pgmq-hs` project's `pgmq-config` package, not `pgmq-core`.
  The runtime conformance suite now depends on `pgmq-config` explicitly and inspects
  the live config fields, proving a FIFO index on the main queue and a standard,
  non-FIFO DLQ without requiring a database.

(To be extended during implementation.)


## Decision Log

- Decision: Intake `PersistDedupeOnly` (E8a) is **in scope** as a one-line optional
  `persist = full-envelope | dedupe-only` clause on the `intake` node, defaulting to
  `full-envelope`.
  Rationale: the runtime surface landed with docs/plans/82 (`InboxPersistence` in
  `keiro/src/Keiro/Inbox/Types.hs`, `runInboxTransactionWith` in
  `keiro/src/Keiro/Inbox.hs`); it is a per-intake data-retention semantic (what the
  inbox table stores on success), exactly the shape of decision this plan already
  lowers for pgmq (a runtime policy enum surfaced as an authoring clause and lowered
  into a generated policy value); and no other MasterPlan-15 plan covers it, so
  deferring would leave it homeless. It costs one AST field, one parser line, one
  pretty-printer line, one generated constant, and one conformance assertion.
  Date: 2026-07-13
- Decision: Delegated-idempotence intake (E8b) is **out of scope** here.
  Rationale: its runtime has NOT landed; docs/plans/83-delegated-idempotence-inbox-
  intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-
  dedupes.md already scopes its own DSL surface as part of delivering the runtime.
  Duplicating a speculative surface here would either drift from plan 83 or force it.
  Date: 2026-07-13
- Decision: Sharding / consumer-group clauses (E8c: `ShardedWorkerOptions`, Kafka
  consumer group tuning) are **out of scope** — permanently deployment-scoped.
  Rationale: shard counts and consumer-group identity are hole-kind 8 (runtime-config
  delegated to deployment) in the DSL's own taxonomy: they vary per environment, carry
  no cross-agent re-derivation hazard, and changing them is an operational action, not
  a spec evolution. The same taxonomy already keeps intake `consumer` blocks
  (brokers/groupId/offsetReset) out of the notation.
  Date: 2026-07-13
- Decision: pgmq message headers, batch enqueue, visibility timeout, batch size,
  polling cadence, and metrics cadence stay **out** of the `workqueue` node.
  Rationale: they are runtime tuning (`JobTuning`, `enqueueWithHeaders*`,
  `enqueueBatch*`, `Keiro.PGMQ.Metrics`), not semantic contracts of the queue. The one
  `JobTuning` field that IS a semantic contract — `ordering` — is exactly what this
  plan lifts into the spec; the scaffold exposes it as a `JobTuning -> JobTuning`
  overlay (`jobTuningFor`) so deployment keeps owning the rest of the record.
  Date: 2026-07-13
- Decision: the group-key derivation supports two strategies: `via raw` (the group key
  IS the payload field's text value; the scaffold emits a total `groupKeyFor`
  projection) and `via <name> fixture "<input> => <output>"` (an opaque hole-kind-1
  derivation that MUST carry a captured fixture, mirroring the physical/dlq/table trio
  discipline; the scaffold emits the deterministic facts and the hole signature in the
  manifest guidance, and the conformance fill must reproduce the fixture).
  Rationale: per-entity FIFO (group = the id field) is the dominant case and should be
  fully generated; anything else is opaque and must be pinned by fixture so two agents
  re-derive it identically.
  Date: 2026-07-13
- Decision: `continueAsNew` is legal only as the *last top-level* body item (not inside
  a `patch` block, not mid-body).
  Rationale: the runtime allows rotation anywhere (it unwinds via an exception), but a
  mid-body rotation makes every later item dead text in the spec — a lie the validator
  should reject. Rotation inside a patch branch is runtime-legal but the spec's flat
  body cannot honestly render "sometimes terminal here"; an author who needs it writes
  it in the filled body (hand code) where it belongs. Revisit if a real corpus spec
  needs conditional rotation.
  Date: 2026-07-13
- Decision: the snapshot `shape-hash` is a captured fixture checked by conformance
  against the live `regFileShapeHash`, NOT re-derived by `check`.
  Rationale: the hash covers module-qualified Haskell type names that depend on
  scaffold placement flags; keiro-dsl's validator has no keiki dependency and must not
  grow one (the package boundary is the firewall's foundation). Spec-side the validator
  checks form (policy implies codec clause, `every N` has N >= 1, version >= 1,
  non-empty hash); the truth of the hash is proven where the types exist — the
  conformance suite. This split is stated explicitly in the NOTATION.md snippet so
  authors know which guarantees come from `check` and which from the harness.
  Date: 2026-07-13
- Decision: validator diagnostics added by this plan reuse the existing
  `DiagnosticCode` enum in `keiro-dsl/src/Keiro/Dsl/Validate.hs` (one constructor per
  rule, tests match on codes). If docs/plans/104 (validator soundness) restructures the
  code registry first, these codes are registered through whatever registry shape it
  lands; the rule *semantics* in this plan are authoritative either way.
  Date: 2026-07-13

(Extend as decisions are made during implementation.)


## Outcomes & Retrospective

M1 is complete. Workqueues now express unordered or FIFO ordering, required FIFO group
keys, and standard/unlogged/partitioned provisioning. `check` rejects missing,
ignored, unresolved, and malformed combinations and warns on the unlogged crash-loss
tradeoff. Generated queue modules expose total raw group-key projection plus live
`JobOrdering`, `JobTuning`, and `QueueProvision` values. The unit suite (184 examples),
queue codec suite, queue runtime suite, and filled dispatch suite are green; the
runtime suite inspects the pure live `queueProvisionConfigs` result to pin the main
queue and DLQ shapes. M2–M5 remain.


## Context and Orientation

### Standing assumption

keiro MasterPlan 14 (docs/masterplans/14-harden-the-keiro-command-coordination-and-
snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md) is implemented **before**
this plan. In particular EP-98's snapshot guards are present in
`keiro-core/src/Keiro/EventStream/Validate.hs` (verified in the working tree): stream
construction via `mkEventStream`/`mkEventStreamOrThrow` fails when a non-`Never`
snapshot policy has no state codec, and fails when the codec cannot encode the initial
state/registers.

### The repository, in one paragraph

This is the keiro monorepo. `keiro-core/` and `keiro/` are the event-sourcing runtime
(event streams over kiroku, process managers, workflows, inbox/outbox);
`keiro-pgmq/` is the typed PGMQ job layer. `keiro-dsl/` is a *toolchain* package — a
parser, validator, scaffolder, and harness emitter over a typed `.keiro` specification
of a service. `keiro-dsl scaffold` emits a deterministic "generated layer" (modules
stamped `-- @generated`) plus typed hole stubs the author fills by hand; the **firewall
invariant** says no generated line may contain a keiki symbolic operator — behaviour
lives in holes, wiring lives in generated code. Conformance test suites under
`keiro-dsl/test/conformance-*` commit a copy of scaffold output and compile it against
the live runtime packages, so runtime drift breaks a build instead of a user.
The authoring skill (how an agent writes specs) lives at
`agents/skills/keiro-dsl-authoring/` — `NOTATION.md` is its grammar reference and every
grammar change in this plan lands a snippet there.

### keiro-dsl modules this plan edits

All paths repo-relative:

- `keiro-dsl/src/Keiro/Dsl/Grammar.hs` — the AST. `WorkqueueNode` (fields `wqName`,
  `wqLogical`, `wqPhysical`, `wqDlq`, `wqTable`, `wqPayloadName`, `wqPayload`,
  `wqMaxRetries`, `wqDelay`, `wqDlqOn`, `wqDisposition`, `wqLoc`), `Aggregate`
  (`aggRegs`, `aggStates`, `aggCommands`, `aggEvents`, `aggTransitions`, `aggWire`,
  `aggProjection`, `aggLoc`), `WfBodyItem` (`WfStep`, `WfAwait`, `WfSleep`, `WfChild`),
  `WorkflowNode`, `IntakeNode` (`inkDedupePolicy`, `inkDecode`, `inkDisposition`, …).
- `keiro-dsl/src/Keiro/Dsl/Parser.hs` — megaparsec parser. `pWorkqueue` (around line
  676) parses the queue/derive/payload/retry/disposition sequence; `pWorkflow` (around
  line 778) parses the header then `many pWfBodyItem`; `pAggregate` (around line 294)
  collects `BodyItem`s (`BICommand`/`BIEvent`/`BIWire`/`BIProjection`/`BITransition`);
  `pIntake` parses the intake block. Helpers: `keyword`, `symbol`, `ident`,
  `stringLit` (no escapes — a docs/plans/105 concern, do not depend on escaping),
  `pWindow` (a duration token like `5s`), `braces`.
- `keiro-dsl/src/Keiro/Dsl/PrettyPrint.hs` — the printer whose output must re-parse to
  an equal AST (`Loc` ignores line numbers in `Eq`). `docWorkqueue` (around line 122),
  `docWorkflow` (around line 76, `bodyItem` local), `docAggregate` (around line 373;
  wire then projection print last), `docIntake`.
- `keiro-dsl/src/Keiro/Dsl/Validate.hs` — `validateSpec` dispatches per node.
  `validateWorkqueue` (line ~157) holds the EP-5 rules (physical-name divergence,
  disposition inversions, dlq ceiling); `validateNode _ (NWorkflow _) = []` today
  (docs/plans/104 owns the general workflow validation framework; this plan adds only
  its own patch/continueAsNew rules there); `DiagnosticCode` is the enum tests match
  on.
- `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` — `scaffoldWorkqueue` emits `Queue.hs`
  (payload record + JSON codec + captured name constants) and `QueuePolicy.hs`
  (`retryPolicy :: RetryPolicy`, `jobOutcomeFor :: Text -> JobOutcome`, compiled
  against the live `Keiro.PGMQ.Job`); `emitEventStream` (around line 1062) emits the
  aggregate's `EventStream` value with `snapshotPolicy = Never, stateCodec = Nothing`
  hardcoded (lines 1095–1096); `emitDomain`/`emitRegsType`/`emitInitialRegs` emit the
  aggregate Domain module (id newtypes, enums, vertex, command/event sums, `RegFile`
  type + initial value); `scaffoldIntake` emits the intake disposition over the live
  `Keiro.Inbox.Types.InboxResult`.
- `keiro-dsl/src/Keiro/Dsl/Harness.hs` — `harnessFor` (aggregate `Harness.hs` with
  `harnessAssertions :: [(String, Bool)]`), `harnessProcess`, `harnessWorkflow`
  (emits `WorkflowFacts.hs` — pure `workflowFacts :: [(String, String)]` — and
  `WorkflowRuntime.hs` — `workflowName`, `awaitAwakeableId` over the live
  `deterministicAwakeableId`, `awaitLabels`).
- `keiro-dsl/src/Keiro/Dsl/Skeleton.hs` — `keiro-dsl new <kind>` starter specs. All
  clauses added by this plan are optional with today's behaviour as the default, so
  skeletons stay valid unchanged; the workqueue and workflow skeletons gain a comment
  line naming the new optional clauses.
- `keiro-dsl/app/Main.hs` — the CLI. The `Scaffold` branch assembles per-node module
  lists; for workflows it emits only `harnessWorkflow` output (see Surprises).
- `keiro-dsl/test/Main.hs` — the unit suite (hspec): parse/pretty round-trips per
  fixture, validator code pins (`errorCodesOf`), scaffold determinism pins. It assumes
  `cwd = keiro-dsl/` (fixture paths are relative — run tests from the package dir).
- `keiro-dsl/test/fixtures/*.keiro` — fixture specs. `reservation-work.keiro` (the
  canonical workqueue+dispatch pair), `reservation.keiro` (the canonical aggregate),
  `workflow.keiro` (the canonical workflow+operations).
- Conformance suites (each a cabal `test-suite` in `keiro-dsl/keiro-dsl.cabal` with a
  committed copy of scaffold output under `test/<suite>/Generated/...`):
  `conformance-queue` (payload codec, pure), `conformance-queue-runtime` (QueuePolicy
  against live `Keiro.PGMQ.Job`), `conformance-workflow` (facts),
  `conformance-workflow-runtime` (awakeable ids against live `Keiro.Workflow`),
  `conformance-workflow-full` (a FILLED body compiled against the live `Workflow`
  effect), `conformance` (the aggregate vertical incl. `EventStream` +
  `mkEventStreamOrThrow`), `conformance-intake-runtime` (intake disposition against
  live `Keiro.Inbox.Types`).

### Runtime surface 1: pgmq ordering and provisioning (`keiro-pgmq/src/Keiro/PGMQ/Job.hs`)

Everything below is exported from `Keiro.PGMQ.Job` (verified against the working
tree). Ordering:

```haskell
data JobOrdering
    = Unordered        -- plain read; msg_id order; NO per-key guarantee under
                       -- concurrency, retries, or visibility-timeout expiry
    | FifoThroughput   -- strict per-group order; batch fills from the oldest
                       -- eligible group first (SQS-style, read_grouped)
    | FifoRoundRobin   -- strict per-group order; fair interleave across groups
                       -- (read_grouped_rr)

data JobTuning = JobTuning
    { visibilityTimeout :: !Int32, batchSize :: !Int32
    , polling :: !JobPolling, ordering :: !JobOrdering }

withOrdering :: JobOrdering -> JobTuning -> JobTuning
```

FIFO groups ride the reserved `x-pgmq-group` JSONB header. The producer side is
`enqueueToGroup :: (Pgmq :> es, IOE :> es) => Job p -> Text -> p -> Eff es MessageId`
(and `enqueueToGroupWithDelay`), which wraps the group key into that header. Within
one group messages are delivered in strict send order; distinct groups proceed in
parallel; delivery is still at-least-once with NO deduplication, so handlers must stay
idempotent. Grouped reads need a GIN index on the queue's `headers` column —
`ensureFifoIndex :: (Pgmq :> es) => Job p -> Eff es ()` creates it idempotently, and
`ensureOrderedJobQueue` composes `ensureJobQueue` + `ensureFifoIndex`.

Provisioning:

```haskell
data QueueKind = StandardKind | UnloggedKind | PartitionedKind !PartitionSpec

data PartitionSpec = PartitionSpec
    { partitionInterval :: !Text   -- pg_partman duration/integer string, e.g. "daily"
    , retentionInterval :: !Text } -- e.g. "7 days"

data QueueProvision = QueueProvision
    { provisionKind :: !QueueKind, provisionFifoIndex :: !Bool }

standardProvision, unloggedProvision :: QueueProvision
partitionedProvision :: PartitionSpec -> QueueProvision
withFifoIndexProvision :: QueueProvision -> QueueProvision

queueProvisionConfigs :: QueueProvision -> Job p -> [Config.QueueConfig]  -- PURE
ensureJobQueueWith :: (Pgmq :> es) => QueueProvision -> Job p -> Eff es ()
```

Semantics that must be embedded in validator messages and NOTATION.md:
an **unlogged** queue's writes skip the write-ahead log (faster) but the table is
**truncated to empty on a database crash** — it trades away crash durability and is
only for transient, regenerable work. A **partitioned** queue needs a
`pg_partman`-enabled server, and its interval/retention are **create-time**
parameters: `ensureJobQueueWith` routes through pgmq-config's *additive* reconciler
(lists existing queues, creates only what is missing), so changing the partition spec
in the spec does NOT migrate an already-created queue. The DLQ (when
`useDeadLetter = True`) is always a plain standard queue with no FIFO index —
`queueProvisionConfigs` pins that. `queueProvisionConfigs` is pure and exposed
precisely so the partitioned path is testable without a `pg_partman` database — the
conformance suite uses it.

### Runtime surface 2: snapshots (`keiro-core/src/Keiro/EventStream.hs`, `keiro/src/Keiro/Snapshot*.hs`)

```haskell
data EventStream phi rs s ci co = EventStream
    { transducer :: …, initialState :: !s, initialRegisters :: !(RegFile rs)
    , eventCodec :: …, resolveStreamName :: …
    , snapshotPolicy :: !(SnapshotPolicy (s, RegFile rs))
    , stateCodec :: !(Maybe (StateCodec (s, RegFile rs))) }

data SnapshotPolicy state
    = Never          -- always rehydrate from the full log
    | Every !Int     -- snapshot when stream version is a multiple of n
                     -- (runtime treats non-positive as disabled)
    | OnTerminal     -- snapshot only when the machine reached a final state
    | Custom !(Terminality -> state -> StreamVersion -> Bool)

data StateCodec state = StateCodec
    { stateCodecVersion :: !Int  -- bump when the encoding changes incompatibly
    , shapeHash :: !Text         -- digest of the folded-state shape
    , encode :: !(state -> Value), decode :: !(Value -> Either Text state) }
```

A stored snapshot is loaded only when BOTH `stateCodecVersion` and `shapeHash` match
the current codec (`keiro/src/Keiro/Snapshot.hs` passes both to `lookupSnapshot`), so
a mismatch transparently falls back to a clean rehydration from events — snapshot
policy changes are always decode-safe. The canonical codec builder is:

```haskell
-- keiro/src/Keiro/Snapshot/Codec.hs
defaultStateCodec ::
    forall rs s. (FromJSON s, KnownRegFileShape rs, RegFileToJSON rs, ToJSON s) =>
    Int -> StateCodec (s, RegFile rs)
```

It serializes `{"state": …, "registers": …}` (registers via keiki's
`regFileToJSON`) and derives `shapeHash = regFileShapeHash (Proxy @rs)` — a SHA-256
over the canonical slot-name + module-qualified-type rendering of the register list
(`keiki` `Keiki.Shape`). The constraints matter for the scaffold: the vertex type `s`
and every register slot type need `ToJSON`/`FromJSON` instances.

EP-98's guards at construction (`keiro-core/src/Keiro/EventStream/Validate.hs`):
`snapshotWarnings` rejects a non-`Never` policy whose `stateCodec` is `Nothing`
("snapshots would never be written"), and `initialSnapshotEncodeWarnings` force-encodes
`(initialState, initialRegisters)` and rejects a codec that throws (catching the
labelled `uninit: <slot>` thunks of `emptyRegFile`). Both run inside
`mkEventStreamOrThrow`, which the generated `EventStream` module already calls — so a
snapshot-enabled generated stream is runtime-checked the moment the conformance suite
forces the value.

What is checkable spec-side vs runtime-checked (this split is a deliverable):

- Spec-side (`keiro-dsl check`): the `snapshot` clause syntactically requires its
  `state-codec` sub-clause (mirrors `snapshotWarnings` by construction); `every N`
  requires N >= 1; `version` >= 1; `shape-hash` non-empty. The DSL's own register
  discipline (every `regs` entry declares an initial value; the scaffold emits an
  explicit `initialRegs` with no `emptyRegFile` thunks) makes the encodable-initial-
  registers constraint hold *by construction* for scaffolded streams — but the
  validator cannot prove it (initials like `placeholder` lower to type-specific
  values in generated Haskell), so it is not claimed.
- Runtime-checked (conformance): `mkEventStreamOrThrow` accepts the stream (this
  exercises BOTH EP-98 guards, including initial-state encodability), and the captured
  `shape-hash`/`version` fixture equals the live codec's `shapeHash`/
  `stateCodecVersion`.

### Runtime surface 3: workflow patch and continue-as-new (`keiro/src/Keiro/Workflow.hs`, `keiro/src/Keiro/Workflow/Types.hs`)

```haskell
patch :: (Workflow :> es) => PatchId -> Eff es Bool
newtype PatchId = PatchId {unPatchId :: Text}
patchStepName :: PatchId -> Text          -- "patch:" <> id
-- WorkflowRunOptions carries: activePatches :: !(Set PatchId)

continueAsNew :: (Workflow :> es, Aeson.ToJSON s) => s -> Eff es a
restoreSeed :: (Workflow :> es, ToJSON s, FromJSON s) => s -> Eff es s
```

`patch` semantics (EP-49): `patch (PatchId "fraud-check-v2")` returns `True` only when
that id was in `activePatches` when this workflow *generation first started*. A fresh
generation journals its active set once under the reserved `patchSetStepName`; each
`patch` call journals its own `Bool` under `patch:<id>` on first encounter, and every
replay returns the recorded value — so an in-flight instance keeps its original branch
forever while fresh instances take the new one. The runtime documentation is explicit
that `patch` is an *escape hatch* for cross-cutting changes (add/remove/reorder steps,
change the meaning of a journaled result); a single changed step should instead be
RENAMED (replay is keyed by step name — the renamed step simply runs fresh). Patch ids
are opaque, never reused, and must not contain a `:` that makes the `patch:` prefix
boundary ambiguous. Add the id to `activePatches` in the deploy that introduces the
`patch` call; remove it only after deleting the call.

`continueAsNew` semantics (EP-48): journal a terminal rotation marker
(`WorkflowContinuedAsNew {generation}`) on the current generation, snapshot the
carried seed onto a fresh journal generation, and unwind the run (its result type is
fully polymorphic because control never returns within this run). The next run/resume
of the same logical `(WorkflowName, WorkflowId)` starts on the fresh generation with a
bounded journal, reading the seed back via `restoreSeed` (an ordinary journaled step
under the reserved `continueSeedStepName`) at the top of the body. Physical journal
streams rotate underneath the stable logical identity: generation 0 keeps
`wf:<name>-<id>`, generation g > 0 appends `#<g>`
(`workflowGenerationStreamName`); wake sources include `currentRunGeneration` in their
durable ids so generations never collide. This is how a poller or per-day rolling
process keeps replay/hydration fast forever.

### Runtime surface 4: intake persistence (`keiro/src/Keiro/Inbox/Types.hs`, `keiro/src/Keiro/Inbox.hs`)

```haskell
data InboxPersistence = PersistFullEnvelope | PersistDedupeOnly
runInboxTransactionWith ::
    …-> InboxPersistence -> InboxDedupePolicy -> … -- plan-82 surface
```

`PersistDedupeOnly` keeps only the columns needed for dedupe and operator triage on
the *success* path; the failure path always persists the full envelope (a failed inbox
row is the operator's dead-letter record). Rows written dedupe-only decode with an
empty payload. `runInboxTransaction` (the default wrapper) is
`runInboxTransactionWith mMetrics PersistFullEnvelope …`.

### Sibling-plan integration points

- docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md
  (**hard dependency for milestone M5 only**): today `Keiro.Dsl.Diff.diffSpecs`
  inspects only `NAggregate` events. Plan 103 makes workqueue policy, workflow bodies
  and identity-bearing fields visible to `diff --since`. Once its per-node diff
  dispatch exists, this plan's M5 registers the refinements listed in the Plan of Work
  (patch-guarded body changes classify safe/additive; unguarded reorders breaking;
  ordering/provision deltas surfaced). The interface this plan expects from 103: a
  per-node hook receiving the old and new node of the same name plus a way to emit
  `Additive`/`Breaking` changes with a `DiagnosticCode`. If 103 lands a different
  shape, reconcile at implementation time and record the delta in both Decision Logs.
- docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-
  node-references-and-disposition-tables.md: owns the general workflow-validation
  framework (duplicate labels, sleep-field resolution, child-id checks) and any
  restructuring of the diagnostic-code registry. This plan adds only its own codes and
  rules; if 104 lands first, register through its registry; if this plan lands first,
  104 inherits the codes.
- docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-
  completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md:
  owns splice escaping and the firewall list. Every new splice in this plan uses
  `tshow` (the escaped string-literal renderer already used throughout Scaffold.hs) —
  never a bare quote-wrap — and every new generated module must stay firewall-clean
  (no keiki symbolic operators; `defaultStateCodec`, `QueueProvision` etc. are keiro
  runtime values, not keiki operators). If 106's shared escape/emit helpers exist by
  implementation time, use them.
- docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-
  and-corpus.md: owns the holistic skill/corpus refresh and the cold-start re-proof.
  This plan lands the per-clause NOTATION.md snippets (the MP-8 discipline); plan 110
  sweeps SKILL/LOOP/WALKTHROUGH and the corpus index over them.
- docs/plans/107 (read-model node) and docs/plans/108 (router node): no interaction;
  the clauses here touch none of their surfaces.

### The MP-8 extension discipline

Per docs/masterplans/8-build-the-keiro-dsl-service-dsl-toolchain.md, every notation
extension ships as one coherent vertical: grammar (AST), parser, pretty-printer (exact
round-trip), generator arm (scaffold/harness lowering), validator rules (including
dangerous-default checks), skeleton compatibility, harness/conformance pinning against
the live runtime, and a NOTATION.md snippet. Each milestone below follows that order.


## Plan of Work

The work is five milestones. M1 (pgmq), M2 (snapshots), M3 (workflow evolution) are
independent of each other and can be done in any order; M4 (intake persist + recorded
decisions) is independent too; M5 (differ refinement) has a hard dependency on
docs/plans/103 and is last. Every milestone leaves the whole test battery green.

### Milestone M1 — workqueue ordering, provisioning, and group key

Scope: the `workqueue` node learns three optional clauses; the validator learns four
rules; the scaffold lowers them into `QueuePolicy.hs`/`Queue.hs` values compiled
against the live `Keiro.PGMQ.Job`; the queue conformance suites pin them. At the end,
`keiro-dsl check` accepts the extended fixture, warns on `provision unlogged`, rejects
a FIFO queue without a group key (and vice versa), and
`cabal test keiro-dsl-conformance-queue-runtime` proves the generated
`queueProvision`/`jobOrdering`/`jobTuningFor`/`groupKeyFor` values behave over the
real runtime types.

Proposed notation (extending the block in `test/fixtures/reservation-work.keiro`; all
three clauses optional, defaults reproduce today's spec meaning exactly):

```text
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"

  ordering fifo-throughput                      # unordered | fifo-throughput | fifo-roundrobin
  group key from reservationId via raw          # required iff ordering is FIFO
  provision standard                            # standard | unlogged | partitioned(interval="daily", retention="7 days")

  payload ReservationWorkItem { ... }
  retry maxRetries = 3 delay = 5s dlq = on
  disposition { ... }
}
```

The opaque-derivation form of the group key carries a captured fixture, mirroring the
physical/dlq/table trio:

```text
  group key from hospitalId via regionOf fixture "hosp-123 => region-9"
```

Grammar (`Keiro.Dsl.Grammar`): add

```haskell
data WqOrdering = WqUnordered | WqFifoThroughput | WqFifoRoundRobin
data WqGroupKey = WqGroupKey
    { gkField :: !Name              -- a payload field name
    , gkVia :: !Name                -- "raw" or an opaque derivation name
    , gkFixture :: !(Maybe Text) }  -- "input => output", REQUIRED unless via=raw
data WqProvision
    = WqStandard | WqUnlogged
    | WqPartitioned !Text !Text     -- interval, retention (pg_partman strings)
```

and extend `WorkqueueNode` with `wqOrdering :: !WqOrdering` (default `WqUnordered`),
`wqGroupKey :: !(Maybe WqGroupKey)`, `wqProvision :: !WqProvision` (default
`WqStandard`). Export the new types.

Parser (`pWorkqueue`): after the `derive` block and before `payload`, parse the three
optional clauses in fixed order (`ordering`, then `group key`, then `provision`) —
fixed order keeps the grammar LL(1) and the printer canonical. Spellings:
`ordering` + one of `unordered`/`fifo-throughput`/`fifo-roundrobin` (note: the lexer's
keyword boundary treats `-` as a non-identifier character, so parse these with
`symbol`, matching how multi-word spellings are handled elsewhere); `group key from
<ident> via <ident> [fixture <stringLit>]`; `provision` + `standard`/`unlogged`/
`partitioned` `(` `interval` `=` stringLit `,` `retention` `=` stringLit `)`. Absent
clauses produce the defaults.

Pretty-printer (`docWorkqueue`): render `ordering`/`group key`/`provision` between the
`derive` lines and `payload`, and render each only when it differs from the default
(`WqUnordered`/`Nothing`/`WqStandard`) — omission and the explicit default parse to
equal ASTs, so `parse . pretty == id` still holds; note in a comment that omission is
canonical. Extend the round-trip property fixtures.

Validator (`validateWorkqueue`) — new `DiagnosticCode` constructors and rules:

- `WqGroupKeyMissing` (Error): `wqOrdering` is FIFO and `wqGroupKey` is `Nothing`.
  Message states why: FIFO reads deliver per *group*; without a declared group key the
  producer's `enqueueToGroup` call site is unspecified and two agents will derive
  different keys.
- `WqGroupKeyWithoutFifo` (Error): `wqGroupKey` present with `WqUnordered` — the key
  would be silently ignored by plain reads (the required-iff-FIFO rule, both
  directions).
- `WqGroupKeyUnresolved` (Error): `gkField` is not a declared `wqPayload` field name;
  additionally, when `gkVia == "raw"` the field's declared wire type must be `text`
  (the group key is a `Text`); when `gkVia /= "raw"` and `gkFixture` is `Nothing`,
  report the missing captured fixture (same code, distinct message).
- `WqUnloggedDurability` (**Warning**): `provision unlogged` — the queue table is
  truncated to empty on a database crash; every queued job is lost. The spec is the
  right place to make that trade visible; the author accepts it by shipping the spec
  with the warning present.
- `WqPartitionSpecEmpty` (Error): `partitioned` with an empty interval or retention
  string. The message also states the create-time caveat (the additive reconciler
  never migrates an existing queue's partition settings).

Scaffold (`emitQueuePolicy` in `Keiro.Dsl.Scaffold`): extend the generated
`QueuePolicy.hs` — still importing only the live `Keiro.PGMQ.Job` — with:

```haskell
-- generated (sketch, for ordering fifo-throughput + provision standard):
import Keiro.PGMQ.Job (JobOrdering (..), JobOutcome (..), JobTuning,
                       QueueProvision, RetryDelay (..), RetryPolicy (..),
                       standardProvision, withFifoIndexProvision, withOrdering)

jobOrdering :: JobOrdering
jobOrdering = FifoThroughput

-- Deployment owns visibility timeout / batch size / polling; the spec owns
-- ordering. Apply this overlay to whatever JobTuning deployment builds.
jobTuningFor :: JobTuning -> JobTuning
jobTuningFor = withOrdering jobOrdering

-- FIFO ordering implies the FIFO GIN index at provision time.
queueProvision :: QueueProvision
queueProvision = withFifoIndexProvision standardProvision
```

Lowering table: `WqUnordered` -> `Unordered` with `queueProvision = <base>`;
FIFO orderings -> `FifoThroughput`/`FifoRoundRobin` with
`withFifoIndexProvision <base>`; base is `standardProvision` / `unloggedProvision` /
`partitionedProvision (PartitionSpec {partitionInterval = <tshow interval>,
retentionInterval = <tshow retention>})`. All string splices via `tshow`. The
generated haddock on `queueProvision` states: pass it to `ensureJobQueueWith` at
worker startup (or use `ensureOrderedJobQueue` for the standard+FIFO case); the DLQ is
always provisioned standard.

`emitWorkqueueGen` (`Queue.hs`): when a group key is present, emit
`groupKeyField :: Text` (the field name) and — for `via raw` — a total projection the
producer hole calls:

```haskell
-- generated (via raw over payload field reservationId):
groupKeyFor :: ReservationWorkItem -> Text
groupKeyFor p = p.reservationId
```

For an opaque `via <name>`, emit `groupKeyField` plus a haddock block naming the
derivation hole (`<name> :: Text -> Text`) and embedding the captured fixture line
verbatim, so the hole filler re-derives identically; the fan-out hole guidance in the
manifest tells the producer to call
`enqueueToGroup job (<name> (groupKeyOf payload)) payload`. No `HoleStub` module is
added for workqueues (they have none today); the hole lives where workqueue behaviour
already lives — the hand-written worker/producer the conformance-dispatch-full pattern
demonstrates.

Fixtures and pins: extend `test/fixtures/reservation-work.keiro` with
`ordering fifo-throughput`, `group key from reservationId via raw`, and keep
`provision` omitted (canonical default) — then add negative fixtures
`reservation-work-fifo-nokey.keiro` (FIFO without group key),
`reservation-work-key-unordered.keiro`, `reservation-work-unlogged.keiro` (expect the
warning, exit 0), `reservation-work-partitioned-empty.keiro`. Unit pins in
`test/Main.hs` under the EP-5 describe block: round-trip of the extended fixture, one
`errorCodesOf`/warning pin per new rule. Regenerate the committed copies under
`test/conformance-queue/Generated/` and `test/conformance-queue-runtime/Generated/`
(run the scaffold, copy the two queue modules), and extend
`test/conformance-queue-runtime/Main.hs`:

```haskell
-- new assertions (sketch):
orderingOk   = jobOrdering == FifoThroughput
provisionOk  = case queueProvisionConfigs queueProvision someJob of
                 (mainCfg : dlqCfgs) -> {- main carries the FIFO index; the DLQ
                                           config list is standard -} …
groupKeyOk   = groupKeyFor sampleItem == "rsv-123"
tuningOk     = (jobTuningFor defaultJobTuning).ordering == FifoThroughput
```

using the PURE `queueProvisionConfigs` so no database (and no `pg_partman`) is needed.
Add the NOTATION.md snippet to the "workqueue / dispatch (EP-5)" section documenting
all three clauses, the defaults, the unlogged warning, the create-time partition
caveat, the required-iff-FIFO group-key rule, and that headers/batch/visibility/
polling/metrics remain deployment tuning (hole-kind 8) by design.

Acceptance: `cabal run keiro-dsl -- check test/fixtures/reservation-work.keiro` exits
0; the negative fixtures produce exactly the pinned codes;
`cabal test keiro-dsl-test keiro-dsl-conformance-queue
keiro-dsl-conformance-queue-runtime` (from `keiro-dsl/`) is green with the new
assertions printed.

### Milestone M2 — aggregate snapshot policy

Scope: aggregates learn an optional `snapshot` clause with a mandatory state-codec
fixture; the scaffold stops hardcoding `Never`/`Nothing` when the clause is present;
a new conformance suite proves the generated stream passes `mkEventStreamOrThrow`
(i.e. both EP-98 guards) and that the captured fixture matches the live codec.

Proposed notation (a new aggregate body clause, printed after `projection`):

```text
aggregate Reservation
  ...
  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transfer_decisions consistency=Strong key=reservationId
    status-map { Created=>held Confirmed=>confirmed }
  snapshot every 100
    state-codec version=1 shape-hash="4f2a…hex…"
```

or `snapshot on-terminal` with the same mandatory `state-codec` sub-clause. The
`Custom` runtime policy is deliberately not exposed (an arbitrary predicate is
hand-code territory, not spec territory — same reasoning that keeps transducer bodies
in holes).

Grammar: add

```haskell
data SnapPolicy = SnapEvery !Int | SnapOnTerminal
data SnapshotSpec = SnapshotSpec
    { snapPolicy :: !SnapPolicy
    , snapCodecVersion :: !Int
    , snapShapeHash :: !Text    -- captured fixture; conformance-verified
    , snapLoc :: !Loc }
```

and `aggSnapshot :: !(Maybe SnapshotSpec)` on `Aggregate`. Parser: a new `BodyItem`
alternative `BISnapshot` in `pBodyItem` (`keyword "snapshot"`, then
`keyword "every" *> decimal` or `symbol "on-terminal"`, then the `state-codec` line
with `version=` decimal and `shape-hash=` stringLit); `pAggregate` takes
`listToMaybe`. Pretty-printer: render after the projection in `docAggregate`, exactly
two lines as shown. Round-trip fixture: a new `reservation-snapshot.keiro` (a copy of
`reservation.keiro` plus the clause — the canonical `reservation.keiro` stays
untouched so the existing committed conformance copies and pins do not churn).

Validator — new codes:

- `SnapshotIntervalInvalid` (Error): `snapshot every N` with N < 1. (The runtime
  quietly disables a non-positive interval; the spec must not encode a lie.)
- `SnapshotCodecFixtureInvalid` (Error): `version` < 1 or empty `shape-hash`.

The clause's shape makes "policy without codec" unwritable (the sub-clause is
syntactically mandatory), mirroring the runtime's `snapshotWarnings` guard by
construction. The plan's Context section states precisely which snapshot guarantees
are spec-side vs runtime-checked; the NOTATION.md snippet repeats that split so
authors don't over-trust `check`.

Scaffold: in `emitEventStream`, when `aggSnapshot` is present replace the two
hardcoded lines with:

```haskell
-- generated (sketch, for `snapshot every 100` / version=1):
import Keiro.Snapshot.Codec (defaultStateCodec)
…
    , snapshotPolicy = Every 100          -- or OnTerminal
    , stateCodec = Just (defaultStateCodec 1)
…
-- The captured spec fixture, exported for the conformance pin:
reservationSnapshotFixture :: (Int, Text)
reservationSnapshotFixture = (1, "4f2a…")
```

(with the module's export list extended accordingly; when the clause is absent the
output is byte-identical to today). `defaultStateCodec` needs `ToJSON`/`FromJSON` on
the vertex type and on every register slot type, so `emitDomain` gains — **only when
the aggregate has a snapshot clause** — an `import Data.Aeson (FromJSON, ToJSON)` and
`deriving anyclass (ToJSON, FromJSON)` (plus `DeriveAnyClass`) on the id newtypes, the
enums, and the vertex type. Conditionality keeps every existing committed conformance
copy byte-stable. These are the *snapshot* encodings, distinct from the event wire
codec: generic instances (constructor names, not wire spellings) are correct here
because snapshots are internal and version+shape-hash gated; the generated haddock
says so.

Where does the author get the hash for the fixture? The scaffold prints it: since the
DSL cannot compute keiki's hash, the workflow is capture-by-red-test — scaffold with a
placeholder hash, run the conformance suite once, and it prints
`expected "<placeholder>" but live regFileShapeHash is "<actual>"`; paste the actual
value into the spec. The NOTATION.md snippet documents this loop explicitly (it is the
same capture discipline as the physical/dlq/table trio, with the conformance suite
playing the re-derivation role the validator plays for the trio).

Conformance: a new cabal test-suite `keiro-dsl-conformance-snapshot`
(`test/conformance-snapshot/`, committed scaffold copy of the
`reservation-snapshot.keiro` aggregate — Domain/Codec/EventStream + the hole fill
reused from the existing `test/conformance/HospitalCapacity/Reservation/Holes.hs`
pattern), depending on `keiro-core`, `keiro`, `keiki`, `aeson`. Its `Main.hs`:

```haskell
main = do
    -- Forcing the validated stream runs keiki validation + BOTH EP-98 snapshot
    -- guards (policy/codec coherence, initial-state encodability).
    _ <- evaluate reservationEventStream
    let live = fromJust (stateCodec reservationEventStreamDef)
        (fixVersion, fixHash) = reservationSnapshotFixture
        versionOk = stateCodecVersion live == fixVersion
        hashOk = shapeHash live == fixHash
        hashDerived = shapeHash live == regFileShapeHash (Proxy @ReservationRegs)
        policyOk = case snapshotPolicy reservationEventStreamDef of
                     Every n -> n == 100; _ -> False
        roundTrip = decode live (encode live (initialState reservationEventStreamDef,
                                              initialRegisters reservationEventStreamDef))
                      == Right (initialState …, initialRegisters …)
```

printing each check and exiting non-zero on any `False`. (The register file's `Eq`
comes from comparing re-encoded JSON if `RegFile` lacks `Eq`; adjust the round-trip
assertion to compare `encode live <$> decode live v == Right v` — decide at
implementation and record it.) Acceptance: the suite is green, and mutating the
committed fixture hash by one character turns exactly the `hashOk` check red —
demonstrating the pin bites.

### Milestone M3 — workflow `patch` and `continueAsNew`

Scope: the workflow body grammar gains a guarded `patch` item and a terminal
`continueAsNew` item; the validator enforces id uniqueness and terminal position; the
two generated workflow harness modules pin the new facts over the live runtime; the
full-service conformance compiles a filled body that actually calls
`patch`/`continueAsNew`/`restoreSeed`.

Proposed notation:

```text
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"
  in ReservationWorkflowInput { reservationId:Id hospitalId:Id }
  out ReservationWorkflowSummary
  id from input.reservationId via idText
  body
    step  create-transfer-hold -> ReservationHold
    patch fraud-check-v2 {                       # guarded new-branch items
      step fraud-check -> FraudCheckResult
    }
    await reservation-confirmation -> ReservationConfirmation
    step  summarize-reservation -> ReservationWorkflowSummary
    continueAsNew RolloverSeed                   # terminal only; seed type
```

A `patch <id> { … }` block means: the enclosed items run only on generations where the
patch id was active at generation start (fresh instances after the deploy); in-flight
generations skip them and keep replaying their journaled branch — the runtime journals
the decision under `patch:<id>` so it is stable across replays. `continueAsNew
<SeedType>` means: after the preceding items, rotate the journal into a fresh
generation carrying a `<SeedType>` seed; the filled body reads it back with
`restoreSeed` at the top. Both semantics paragraphs go into NOTATION.md, including the
runtime's own guidance that a *single* changed step should be RENAMED rather than
patched, that patch ids are never reused and must not contain `:`, and that a patch id
is removed from the spec only after the guarded change is permanent.

Grammar: extend `WfBodyItem` with

```haskell
    | -- | @patch <patch-id> { <items> }@ — guard body items behind an EP-49 patch
      WfPatch !Name ![WfBodyItem]
    | -- | @continueAsNew <SeedType>@ — EP-48 rotation; terminal, top-level only
      WfContinueAsNew !Name
```

Parser (`pWfBodyItem`): two new alternatives — `keyword "patch" *> wireWord` then
`braces (many pWfBodyItem)` (labels like `fraud-check-v2` are `wireWord`s, matching
the existing step-label lexing), and `keyword "continueAsNew" *> ident` (a type name).
Reserve `patch` and `continueAsNew` in the keyword table next to the existing EP-6
reservations. Pretty-printer (`docWorkflow.bodyItem`): render the block form with the
nested items indented; render `continueAsNew` as shown. Round-trip: extend
`test/fixtures/workflow.keiro`'s sibling fixture (add
`workflow-evolution.keiro` carrying both new items so the canonical `workflow.keiro`
and its committed conformance copies stay stable) plus negative fixtures
`workflow-patch-dup.keiro`, `workflow-can-mid.keiro`, `workflow-patch-colon.keiro`.

Validator — this plan's rules live in a new `validateWorkflow` limited to its own
concerns (`validateNode` currently returns `[]` for workflows; docs/plans/104 owns the
broader framework — see the integration note):

- `WorkflowPatchDuplicate` (Error): the same patch id appears twice anywhere in the
  body (including nested). Patch ids journal under `patch:<id>`; a duplicate makes two
  distinct guards share one journaled decision.
- `WorkflowPatchIdInvalid` (Error): a patch id containing `:` (the `patch:` prefix
  boundary would be ambiguous, per the `PatchId` haddock in
  `keiro/src/Keiro/Workflow/Types.hs`).
- `WorkflowContinueAsNewNotTerminal` (Error): a `WfContinueAsNew` that is not the last
  top-level item, or that appears inside a `patch` block (see Decision Log).

Harness lowering (`Keiro.Dsl.Harness`):

- `emitWorkflowFacts`: `bodyTag` gains arms — `patch:<id>(<nested tags>)` and
  `continueAsNew:<SeedType>` — so the facts pin the guarded structure, and a new fact
  `("patches", "fraud-check-v2,…")` lists declared ids. The existing hand-written
  expectation in `test/conformance-workflow/Main.hs` is extended; the workflow
  mutation script (`test/workflow-mutation-test.sh`) gains a mutation (drop a patch
  guard) that must redden a specific assertion.
- `emitWorkflowRuntime`: compiled against the LIVE runtime, add

```haskell
-- generated (sketch):
import Data.Set (Set)
import Data.Set qualified as Set
import Keiro.Workflow (WorkflowRunOptions (..))
import Keiro.Workflow.Types (PatchId (..), patchStepName, …)

declaredPatches :: Set PatchId
declaredPatches = Set.fromList [PatchId "fraud-check-v2"]

-- The journal keys the runtime records patch decisions under.
declaredPatchStepNames :: [Text]
declaredPatchStepNames = map patchStepName (Set.toList declaredPatches)

-- Activate exactly the spec's patches on a run: the deploy that ships the
-- spec's `patch` item is the deploy that activates it.
withDeclaredPatches :: WorkflowRunOptions -> WorkflowRunOptions
withDeclaredPatches opts = opts{activePatches = declaredPatches}
```

  This is the faithful lowering of EP-49's contract: the spec is the single place a
  patch id is declared, and the generated overlay keeps `activePatches` in lockstep
  with the body's `patch` calls. When the body has no patch items the three
  declarations are still emitted (empty set) so the module surface is stable.
- `conformance-workflow-runtime/Main.hs` gains assertions that
  `declaredPatchStepNames == ["patch:fraud-check-v2"]` (pinning the live
  `patchStepName` prefixing) and that `withDeclaredPatches
  defaultWorkflowRunOptions` carries exactly the declared set.
- `conformance-workflow-full`: the committed filled body gains a `patch` call guarding
  a step and a rotation tail (`continueAsNew` + `restoreSeed` at the top), compiled
  against the live `Keiro.Workflow` effect — proving the notation's items map onto
  real, type-checking runtime calls. The suite keeps its compile-and-assert shape (no
  database).

CLI: no change needed — `harnessWorkflow` output is already wired in
`app/Main.hs`. State in the manifest/haddock (as today) that workflows have no domain
scaffold or hole stub: the body is hand code pinned by facts + runtime conformance.

Acceptance: extended fixtures round-trip; the three negative fixtures produce exactly
their codes; `cabal test keiro-dsl-conformance-workflow
keiro-dsl-conformance-workflow-runtime keiro-dsl-conformance-workflow-full` green;
`test/workflow-mutation-test.sh` still turns its mutations red.

### Milestone M4 — intake `persist` clause and the recorded scope decisions

Scope: the small E8a surface, plus making the E8b/E8c decisions durable (they are
already in the Decision Log; this milestone lands the NOTATION.md text that states
them user-facing).

Notation: one optional line in the `intake` block, next to the dedupe clauses:

```text
intake reservationIntake {
  ...
  dedupe key = messageId policy = preferIntegrationMessageId
  persist = dedupe-only                # optional; default full-envelope
  ...
}
```

Grammar: `inkPersist :: !InkPersist` on `IntakeNode` with
`data InkPersist = InkPersistFull | InkPersistDedupeOnly` (default `InkPersistFull`).
Parser: optional clause after the dedupe line (`symbol "persist" *> symbol "=" *>`
(`full-envelope` | `dedupe-only`)). Printer: render only when non-default. Validator:
no new rule (both values are safe; the dangerous inversions live in the disposition
table, unchanged). Scaffold (`scaffoldIntake`'s generated module, which already
imports `Keiro.Inbox.Types`): add

```haskell
-- generated:
inboxPersistence :: InboxPersistence
inboxPersistence = PersistDedupeOnly   -- or PersistFullEnvelope
```

with a haddock stating: pass this to `runInboxTransactionWith`; the failure path
always persists the full envelope regardless (the failed row is the operator's
dead-letter record), and dedupe-only rows decode with an empty payload — choose it
only when the envelope payload is re-fetchable or worthless after success.
`conformance-intake-runtime` regenerates its committed copy and asserts the constant's
value. Fixture: extend `test/fixtures/intake.keiro` (round-trip + accept pin).
NOTATION.md: document the clause and, in the same section, one paragraph each for the
two recorded exclusions — delegated-idempotence intake is arriving with
docs/plans/83 (runtime not landed; that plan owns its DSL surface), and
sharding/consumer-group settings are deployment-scoped (hole-kind 8) permanently.

Acceptance: round-trip + validator pins green;
`cabal test keiro-dsl-conformance-intake-runtime` green with the new assertion.

### Milestone M5 — differ refinement over workflow bodies and workqueue policy (hard dependency: docs/plans/103)

Scope: once plan 103's per-node diff dispatch makes workflow bodies and workqueue
nodes visible to `diff --since`, register this plan's classification refinements. Do
not start this milestone until 103's dispatch exists; if 103 ships its own
workflow-body rules first, reconcile there and record the outcome in both Decision
Logs.

Rules to register (semantics are authoritative here even if the hook shape changes):

- A workflow body change (insert/remove/reorder of labelled items) **entirely guarded
  by a `patch` block whose id is new in this spec revision** classifies ADDITIVE: the
  runtime journals the patch decision per generation, so in-flight instances replay
  their old branch and only fresh generations take the new one — this is precisely the
  sanctioned mechanism.
- An **unguarded** reorder/insertion/removal of body items classifies BREAKING
  (in-flight journals replay by label against a body whose label sequence changed);
  the message names `patch` as the guard and step-rename as the single-step
  alternative.
- Removing a `patch` item whose id existed in the old spec classifies BREAKING (the
  runtime doc allows removal only after the call is deleted from code *and* no
  generation still replays the old branch — undecidable spec-side, so the differ is
  conservative).
- Appending a `continueAsNew` terminal item classifies ADDITIVE (rotation markers are
  additive within journal `schemaVersion = 1`; old generations never carry the tag).
  Changing its seed *type* classifies BREAKING (the next generation's `restoreSeed`
  decodes the previous generation's seed).
- Workqueue: an `ordering` change in either direction classifies BREAKING (the
  delivery-order contract consumers were written against changes; FIFO->unordered
  silently drops the per-group guarantee, unordered->FIFO makes un-grouped producers'
  messages unreachable by grouped reads). A `provision` kind or partition-spec change
  classifies BREAKING with the create-time caveat in the message (the reconciler will
  NOT apply it to an existing queue — it must be an operational migration). A
  `group key` derivation change classifies BREAKING (per-entity ordering silently
  re-partitions).

Each rule gets a `diff`-path pin in `test/Main.hs` (fixture pairs, matching on the
`DiagnosticCode`/detail), following the existing `diffFixtures` pattern.


## Concrete Steps

All commands run from the package directory `keiro-dsl/` inside the repo (the unit
suite's fixture paths are relative — running from the repo root shows phantom
failures; see audit note C8).

Build and baseline before touching anything:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl
cabal build keiro-dsl
cabal test keiro-dsl-test
```

Expected tail of the baseline test run:

```text
Finished in …
58 examples, 0 failures
```

Per milestone, the loop is: edit Grammar -> Parser -> PrettyPrint, extend the fixture,
and check the round-trip immediately:

```bash
cabal run keiro-dsl -- parse test/fixtures/reservation-work.keiro
cabal run keiro-dsl -- check test/fixtures/reservation-work.keiro
```

`parse` must print the spec back (the printed form re-parses to an equal AST — the
unit suite asserts it); `check` prints `OK` for valid fixtures. For negative fixtures
compare stderr against the pinned diagnostic, e.g.:

```text
test/fixtures/reservation-work-fifo-nokey.keiro:3: error[WqGroupKeyMissing]: workqueue 'reservation_work': ordering fifo-throughput requires a 'group key' clause …
```

and for the unlogged warning (exit code 0):

```text
test/fixtures/reservation-work-unlogged.keiro:3: warning[WqUnloggedDurability]: workqueue 'reservation_work': provision unlogged is truncated to empty on a database crash …
```

Regenerating a committed conformance copy after a scaffold change (M1 example):

```bash
cabal run keiro-dsl -- scaffold test/fixtures/reservation-work.keiro --out /tmp/keiro-dsl-scaffold
cp /tmp/keiro-dsl-scaffold/Generated/HospitalCapacity/Reservation_work/Queue.hs \
   /tmp/keiro-dsl-scaffold/Generated/HospitalCapacity/Reservation_work/QueuePolicy.hs \
   test/conformance-queue-runtime/Generated/HospitalCapacity/Reservation_work/
```

(mirror into `test/conformance-queue/Generated/…` for the codec module; check the
scaffold report on stderr says `firewall: OK`). Then:

```bash
cabal test keiro-dsl-conformance-queue keiro-dsl-conformance-queue-runtime
```

Expected new output lines from the runtime suite:

```text
storeFailure => Retry (transient): True
decodeFailure => Dead (poison): True
retry ceiling + dlq on: True
ordering lowered to FifoThroughput: True
provision: FIFO index on main queue + standard DLQ: True
groupKeyFor projects the payload field: True
jobTuningFor overlays ordering onto deployment tuning: True
```

M2 adds a cabal stanza; edit `keiro-dsl.cabal` to add the
`keiro-dsl-conformance-snapshot` test-suite (copy the shape of the existing
`test-suite keiro-dsl-conformance` stanza, adding `keiro` and `aeson` to
build-depends, `hs-source-dirs: test/conformance-snapshot`, and the committed
generated modules as `other-modules`). The capture loop for the shape hash:

```bash
cabal run keiro-dsl -- scaffold test/fixtures/reservation-snapshot.keiro --out /tmp/keiro-dsl-snap
# commit the copy with the placeholder hash, then:
cabal test keiro-dsl-conformance-snapshot
# the suite prints the live hash on mismatch; paste it into the fixture's
# shape-hash="…", re-scaffold, re-copy, re-run: all checks True.
```

M3 and M4 follow the same edit/round-trip/pin/regenerate/conformance loop over the
workflow and intake fixtures and suites (`keiro-dsl-conformance-workflow`,
`keiro-dsl-conformance-workflow-runtime`, `keiro-dsl-conformance-workflow-full`,
`keiro-dsl-conformance-intake-runtime`), plus:

```bash
./test/workflow-mutation-test.sh
```

which must keep turning its mutations red.

Final sweep (still from `keiro-dsl/`):

```bash
cabal test
```

Every suite green. Commit per milestone with conventional-commit messages, e.g.
`feat(keiro-dsl): workqueue ordering, provisioning, and group-key clauses (MP-15 EP-109 M1)`.


## Validation and Acceptance

The change is accepted when a novice can demonstrate, with only this working tree:

1. **pgmq**: `cabal run keiro-dsl -- check test/fixtures/reservation-work.keiro`
   prints `OK`; checking the fifo-nokey / key-unordered / partitioned-empty fixtures
   exits non-zero with exactly the codes `WqGroupKeyMissing`, `WqGroupKeyWithoutFifo`,
   `WqPartitionSpecEmpty`; the unlogged fixture exits 0 while printing the
   `WqUnloggedDurability` warning; `cabal test keiro-dsl-conformance-queue-runtime`
   prints the seven `True` lines shown above. Mutating the committed
   `QueuePolicy.hs`'s `jobOrdering` to `Unordered` turns the ordering assertion
   `False` (run once to see it, then revert) — the pin bites.
2. **snapshots**: `cabal test keiro-dsl-conformance-snapshot` passes, which proves at
   once that (a) the generated stream with `snapshotPolicy = Every 100, stateCodec =
   Just (defaultStateCodec 1)` is accepted by `mkEventStreamOrThrow` — i.e. keiki
   validation plus both EP-98 guards, including initial-state encodability — and
   (b) the spec's captured `(version, shape-hash)` fixture equals the live codec's
   values, with the hash independently re-derived via
   `regFileShapeHash (Proxy @ReservationRegs)`. Editing one hex character of the
   fixture and re-scaffolding turns exactly the `hashOk` check red.
3. **workflow evolution**: the evolution fixture round-trips through
   `parse`; the dup-patch / mid-body-continueAsNew / colon-id fixtures produce
   `WorkflowPatchDuplicate`, `WorkflowContinueAsNewNotTerminal`,
   `WorkflowPatchIdInvalid`; the workflow-runtime conformance prints a `True` line for
   `patchStepName` prefixing (`patch:fraud-check-v2`) and for the
   `withDeclaredPatches` overlay; conformance-workflow-full compiles a filled body
   that calls `patch`, `restoreSeed`, and `continueAsNew` against the live
   `Keiro.Workflow` effect.
4. **intake persist**: the intake fixture with `persist = dedupe-only` round-trips and
   checks OK; `keiro-dsl-conformance-intake-runtime` asserts
   `inboxPersistence == PersistDedupeOnly` over the live `Keiro.Inbox.Types`.
5. **No regressions**: `cabal test` from `keiro-dsl/` is fully green, and a scaffold
   of every canonical fixture reports `firewall: OK`. Specs that use none of the new
   clauses scaffold byte-identically to before (verify by re-scaffolding
   `test/fixtures/reservation.keiro` and diffing against the committed
   `test/conformance/Generated/…` copies — empty diff).
6. **M5** (post plan 103): the diff fixture pairs classify as specified — in
   particular, a body change guarded by a new `patch` prints `ADDITIVE: …` and exits
   0, while the same change unguarded prints `BREAKING: …` and exits non-zero.


## Idempotence and Recovery

Every step is re-runnable. Scaffolding is deterministic (pinned by the existing
determinism tests), so regenerating committed conformance copies is idempotent:
re-running the scaffold + copy produces an empty git diff once correct. The
capture-by-red-test loop for the snapshot shape hash converges in one iteration and
re-running it is a no-op. All grammar additions are optional clauses whose absence
reproduces today's AST, printer output, and scaffold output byte-for-byte, so partial
progress never breaks existing fixtures or suites; if a milestone must be abandoned
midway, reverting its commits restores a green tree (commit per milestone, not per
file). No step touches a database, a queue, or any runtime package; the only
destructive-looking operation is overwriting committed `Generated/` copies, which are
regenerable from the fixture spec at any time. If a regenerated copy breaks a
conformance build, diff it against `git show HEAD -- <path>` to see exactly what the
scaffold change introduced.


## Interfaces and Dependencies

Runtime modules **consumed** (read-only; never edited) and the symbols each milestone
compiles generated code against:

- `Keiro.PGMQ.Job` (keiro-pgmq): `JobOrdering (..)`, `JobTuning`, `withOrdering`,
  `QueueProvision`, `QueueKind (..)`, `PartitionSpec (..)`, `standardProvision`,
  `unloggedProvision`, `partitionedProvision`, `withFifoIndexProvision`,
  `queueProvisionConfigs`, `ensureJobQueueWith`, `ensureFifoIndex`,
  `ensureOrderedJobQueue`, `enqueueToGroup`, plus the already-consumed
  `RetryPolicy (..)`, `JobOutcome (..)`, `RetryDelay (..)`.
- `Keiro.EventStream` (keiro-core): `SnapshotPolicy (..)`, `StateCodec (..)`,
  `EventStream (..)`. `Keiro.EventStream.Validate`: `mkEventStreamOrThrow`,
  `ValidatedEventStream`. `Keiro.Snapshot.Codec` (keiro): `defaultStateCodec`.
  `Keiki.Shape` (keiki): `regFileShapeHash`, `KnownRegFileShape` (conformance only).
- `Keiro.Workflow` (keiro): `WorkflowRunOptions (..)`, `patch`, `continueAsNew`,
  `restoreSeed`. `Keiro.Workflow.Types`: `PatchId (..)`, `patchStepName`, plus the
  already-consumed `WorkflowName (..)`, `WorkflowId`;
  `Keiro.Workflow.Awakeable.deterministicAwakeableId` (unchanged).
- `Keiro.Inbox.Types` (keiro): `InboxPersistence (..)` (alongside the already-consumed
  `InboxResult (..)`, `InboxDedupePolicy (..)`).

New/changed keiro-dsl surface at completion:

- `Keiro.Dsl.Grammar`: `WqOrdering (..)`, `WqGroupKey (..)`, `WqProvision (..)` +
  three new `WorkqueueNode` fields; `SnapPolicy (..)`, `SnapshotSpec (..)` +
  `aggSnapshot` on `Aggregate`; `WfPatch`/`WfContinueAsNew` constructors on
  `WfBodyItem`; `InkPersist (..)` + `inkPersist` on `IntakeNode`.
- `Keiro.Dsl.Validate`: new `DiagnosticCode` constructors `WqGroupKeyMissing`,
  `WqGroupKeyWithoutFifo`, `WqGroupKeyUnresolved`, `WqUnloggedDurability`,
  `WqPartitionSpecEmpty`, `SnapshotIntervalInvalid`, `SnapshotCodecFixtureInvalid`,
  `WorkflowPatchDuplicate`, `WorkflowPatchIdInvalid`,
  `WorkflowContinueAsNewNotTerminal`, with rules as specified per milestone.
- `Keiro.Dsl.Scaffold`: `emitQueuePolicy` additionally emits
  `jobOrdering :: JobOrdering`, `jobTuningFor :: JobTuning -> JobTuning`,
  `queueProvision :: QueueProvision`; `emitWorkqueueGen` additionally emits
  `groupKeyField :: Text` and (raw derivations) `groupKeyFor :: <Payload> -> Text`;
  `emitEventStream` lowers `aggSnapshot` to `snapshotPolicy`/`stateCodec =
  Just (defaultStateCodec n)` and exports `<agg>SnapshotFixture :: (Int, Text)`;
  `emitDomain` conditionally derives `ToJSON`/`FromJSON`; `scaffoldIntake` emits
  `inboxPersistence :: InboxPersistence`.
- `Keiro.Dsl.Harness`: `emitWorkflowFacts` body tags for patch/continueAsNew + a
  `patches` fact; `emitWorkflowRuntime` additionally exports
  `declaredPatches :: Set PatchId`, `declaredPatchStepNames :: [Text]`,
  `withDeclaredPatches :: WorkflowRunOptions -> WorkflowRunOptions`.
- Test suites: `keiro-dsl-conformance-snapshot` (new stanza in `keiro-dsl.cabal`);
  extended `Main.hs` + regenerated committed `Generated/` copies for
  conformance-queue, conformance-queue-runtime, conformance-workflow,
  conformance-workflow-runtime, conformance-workflow-full,
  conformance-intake-runtime; new fixtures and pins in `test/Main.hs` and
  `test/fixtures/`.
- Docs: per-clause snippets in `agents/skills/keiro-dsl-authoring/NOTATION.md`
  (workqueue ordering/group-key/provision; aggregate snapshot incl. the spec-side vs
  runtime-checked split and the hash-capture loop; workflow patch/continueAsNew incl.
  the rename-vs-patch guidance; intake persist; the two recorded exclusions).

Dependency posture: hard dependency on docs/plans/103 for M5 only; soft coordination
with docs/plans/104 (diagnostic registry shape), docs/plans/106 (splice/firewall
helpers), docs/plans/110 (consumes the NOTATION snippets). M1–M4 have no cross-plan
blockers. Effort framing (no wall-clock estimates, per repo policy): M1 is the widest
surface (three clauses through seven layers) but mechanically patterned on EP-5; M2's
risk concentrates in the aeson-derivation conditionality and the hash-capture loop;
M3's risk is grammar ambiguity around nested bodies (mitigated by the braces block
form); M4 is trivial; M5 is small but blocked.
