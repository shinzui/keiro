# API Reference

This is a user-facing map of Keiro's public modules. It is not a replacement for
Haddock, but it records which module to import for each task.

## `Keiro`

Top-level convenience module. Re-exports:

- `Keiro.Command`;
- `Keiro.Codec`;
- `EventStream`;
- `Keiro.EventStream.Validate`;
- `SnapshotPolicy`;
- `StateCodec`;
- `Keiro.Router`;
- `Keiro.Snapshot`;
- `Keiro.Stream`.

It also exports `version` (the library version string).

Read-model, projection, process-manager, timer, workflow, wake, subscription-shard,
outbox, inbox, integration-event, replay-audit, and telemetry APIs are exposed as
direct modules and are not re-exported from `Keiro`.

## `Keiro.Stream`

Types and functions:

- `Stream (..)`
- `stream`
- `streamName`
- `mapStreamName`
- `StreamCategory (..)`, `CategoryError (..)`, `category`, `categoryUnsafe`,
  `categoryName`, `categoryText`
- `StreamIdSegment (..)`, `entityStream`, `entityStreamId`

Use it to construct typed stream names. Prefer `entityStream`/`entityStreamId`
over raw `stream` for aggregates: they build `<category>-<id>` names through a
validated `StreamCategory`, which is what Kiroku category subscriptions key on.

## `Keiro.Codec`

Types and functions:

- `Codec (..)`
- `EventType`
- `Upcaster`
- `CodecError (..)`
- `CodecConfigError (..)`
- `mkCodec`
- `encodeForAppend`
- `encodeForAppendWithMetadata`
- `decodeRecorded`
- `decodeRaw`
- `migrateToCurrent`
- `extractSchemaVersion`
- `metadataFor`

Use it to encode domain events into Kiroku event data and decode recorded
events during hydration or projection handling. Prefer `mkCodec` over the raw
`Codec` constructor; `validateEventStreamWith` runs it anyway when building a
`ValidatedEventStream`.

## `Keiro.Codec.Structural`

Types and functions:

- `StructuralBinding (..)`
- `FixtureCases (..)`
- `bindingDomainRoundTrip`
- `bindingShapeRoundTrip`
- `encodeViaBinding`
- `decodeViaBinding`

This is the stable boundary between a consumer-owned Haskell type and the
private shape generated from a `mapped structural` declaration. A binding is
total in both directions and contains no wire policy. `encodeViaBinding` and
`decodeViaBinding` support the sanctioned delegation direction when a consumer
JSON instance should call the generated shape codec; generated structural
codecs never delegate authority to a consumer instance.

## `Keiro.Codec.Structural.Generic`

Types and functions:

- `GNominalBinding`
- `genericStructuralBinding`

Use the opt-in generic binding only when constructor names/order, selector
names/order, arity, and field types match exactly. Any mismatch is a compile
error directing the author to fill the create-once binding skeleton instead.
The derivation constructs/destructs values only; it cannot change keys, tags,
presence, nullability, or defaults.

## `Keiro.EventStream`

Types:

- `EventStream (..)`
- `SnapshotPolicy (..)`
- `StateCodec (..)`

Use it to define an aggregate stream contract around a Keiki transducer.

## Generated version-2 aggregate transducer

`keiro-dsl scaffold` emits one authoritative behavior module for each
language-version-2 aggregate:

- `Generated.<Context>.<Aggregate>.Transducer` exports the assembled transducer,
  the aggregate fold fingerprint, `BehaviorOwnership (GeneratedOwned,
  HoleOwned)`, and an aggregate-specific `...PredicateVerifications` action.
- For a candidate-language-5 aggregate declaring typed outcomes,
  `Generated.<Context>.<Aggregate>.EventStream` additionally exports
  `<aggregate>DomainCommandHandler`. It pairs the validated stream with a pure
  classifier over the exact selected `EdgeRef` and uses only public
  `Keiro.Command` types.

Each generated-owned `B.onCmd` block contains its checked guard, ordered writes,
emits, and target together. Scalar operators use Keiki's readable infix surface.
Nested structural and nominal equality projections are bound once under local
business-shaped names such as `commandLimitsMinimum`; those aliases still apply
the checked generated witness and are not a second behavior authority.

The verification action returns labelled ownership and the conservative
`PredicateVerification` result from `mori://shinzui/keiki/packages/keiki` for
every transition. Opaque Hole predicates remain `UnverifiedOpaque`.

Generated-owned transitions execute the declared guard and writes directly.
For a source transition marked `implementation hole`, the create-once
`<Context>.<Aggregate>.Holes` module instead exposes a stable transition
function and `FoldVersion`; generated code continues to own its structural
command/event/target/mode envelope. Event-output field hooks remain create-once
in both modes. Do not construct a replacement aggregate transducer in the
Holes module, and bump the per-transition `FoldVersion` whenever Hole predicate
or update behavior changes.

The generated outcome classifier has one nested source-state/edge-index arm per
rejected or no-op live edge. It evaluates only the selected checked Keiki term
against pre-command values and raises a generated invariant naming the
aggregate and edge if called with an impossible reference. It contains no map,
linear lookup, repeated guard evaluation, or create-once reason hole. Generated
behavior conformance compares `RejectedWith`/`NoOpWith` witness values against
this public handler after independently checking edge identity and silent-state
preservation.

## `Keiro.EventStream.Validate`

Types and functions:

- `EventStreamWarning (..)`
- `ValidatedEventStream`
- `unvalidated`
- `validateEventStream`
- `validateEventStreamWith`
- `mkEventStream`
- `mkEventStreamWith`
- `mkEventStreamOrThrow`
- `mkEventStreamUnchecked`

Use it to turn a raw `EventStream` definition into the `ValidatedEventStream`
required by command runners, projections, routers, and process managers. Prefer
`mkEventStream` in application startup code when you want to handle warnings
explicitly; use `mkEventStreamOrThrow` for generated code and fixtures that have
a sibling validation proof.
`mkEventStreamUnchecked` bypasses every replay-contract check and is reserved
for tests and emergency forensics.

## `Keiro.Command`

Types and functions:

- `CommandResult (..)`
- `DomainDecision (..)`
- `DomainCommandOutcome (..)`
- `SilentCommandContext (..)`
- `SilentDomainDecision (..)`
- `DomainCommandHandler (..)`
- `CommandError (..)`
- `HydrationReplayReason (..)`
- `RunCommandOptions (..)`
- `defaultRunCommandOptions`
- `runCommand`
- `runDomainCommand`
- `forgetDomainDecision`
- `runCommandWithSql`
- `runCommandWithSqlEvents`
- `SqlTransactionDecision (..)`, `SqlCommandOutcome (..)`,
  `runCommandWithSqlEventsControlled`
- `runDomainCommandWithSql`
- `runDomainCommandWithSqlEvents`
- `DomainSqlCommandOutcome (..)`,
  `runDomainCommandWithSqlEventsControlled`
- `commandErrorClass`
- `Hydrated (..)`, `hydrate`, `hydrateFull`, `hydrateSeeded`

The `hydrate*` helpers expose the read-only half of the cycle (rebuild
`(state, registers)` at a version) for tooling and diagnostics; `commandErrorClass`
maps a `CommandError` onto a stable class string for metrics and logs.

Use it for the canonical load, streaming replay, decide, append command cycle.
Commands may append zero, one, or many produced events as one store batch.
All three runners require `ValidatedEventStream` as their stream argument.
Transactional runners also require `KirokuStoreResource` so Kiroku's configured
event enrichment runs before append preparation.

`DomainCommandHandler` classifies an already-selected state-preserving silent
edge as typed rejection or no-op. `runDomainCommand` returns accepted with the
exact non-empty event batch, or the classifier's payload, together with the
ordinary `CommandResult`. No match and every infrastructure failure remain
`CommandError`. On optimistic retry, only the final evaluation is returned.
Transactional domain callbacks run only for accepted appends; silent decisions
have no append transaction for durable side effects. `forgetDomainDecision`
provides the additive compatibility collapse for successfully matched commands.

## `Keiro.Snapshot`

Types and functions:

- `SnapshotSeed (..)`
- `SnapshotMissReason (..)`
- `SnapshotLookup (..)`
- `lookupSnapshotSeed`
- `hydrateWithSnapshot`
- `encodeSnapshotStrict`
- `writeSnapshotEncoded`
- `writeSnapshot`
- `FoldVersion (..)`, `defaultStateCodec`,
  `defaultStateCodecWithFold`, and `withFoldFingerprint` from
  `Keiro.Snapshot.Codec`;
- re-exports from `Keiro.Snapshot.Schema`.

Most applications use snapshots indirectly through `EventStream.stateCodec` and
`runCommand`. Prefer `defaultStateCodecWithFold` for a hand-written fold and
change its `FoldVersion` whenever event-folding behavior changes.

## `Keiro.Snapshot.Schema`

Types and functions:

- `SnapshotRow (..)`
- `SnapshotWrite (..)`
- `lookupSnapshot`
- `writeSnapshotRow`

Use it for operational tooling. The `keiro_snapshots` table is created by
`keiro-migrate`; see [Database Migrations](migrations.md).

## `Keiro.Projection`

Types and functions:

- `InlineProjection (..)`
- `AsyncProjection (..)`
- `AsyncApplyOutcome (..)`
- `ProjectionCommandOutcome (..)`
- `DomainProjectionCommandOutcome (..)`
- `CatalogAsyncApplyOutcome (..)`
- `runCommandWithProjections`
- `runDomainCommandWithProjections`
- `runCommandWithCatalogProjections`
- `runDomainCommandWithCatalogProjections`
- `applyAsyncProjection`
- `applyAsyncProjectionFromCatalog`
- `applyAsyncProjectionUnfenced`
- `pruneAsyncProjectionDedupBefore`
- `recordProjectionGlobalPositionDistance`
- `recordProjectionLag` (deprecated compatibility alias)

Use the catalog-derived entry points for managed projections: both consult the
same rebuild-group fence inside the append or dedup/write transaction and
return typed outcomes when the group is unavailable. The older entry points are
the unmanaged compatibility surface.

Use inline projections for same-transaction read-model writes. Use async
projection helpers for at-least-once subscription handlers. `Router` and
`ProcessManager` can also run target inline projections during reactor
dispatch by carrying them in `targetProjections`. Use that field when a reactor
or immediate reader needs read-your-own-writes for the target aggregate after
dispatch. Keep it empty for ordinary fan-out, analytics, reporting tables,
integration publishing, or any projection work that can be eventually
consistent; inline projection SQL runs inside the append transaction and can
slow or fail the dispatch.

The domain-aware inline runners apply only accepted event pairs. Typed
rejection/no-op returns its `DomainCommandOutcome` without invoking projection
SQL. A catalog fence after an accepted append is represented separately because
the condemned transaction has no durable command outcome.

## `Keiro.Projection.Catalog`

Use this module to declare and validate one projection inventory before startup
registration or rebuild work. The public boundary includes:

- validated identity smart constructors for projections, targets, rebuild
  groups, sources, query models, subscriptions, dedup keys, and claim sites;
- `ProjectionCatalog`, `ProjectionSet event`, `SomeProjectionSet`, target,
  group, source, subscription, dedup, and query-model declarations;
- independent `TargetResetPolicy` and `ProjectionReplayPolicy event` values;
- `ReplayAdapter`, `ReplayDecodeResult`, and `replayAdapterFromCodec`;
- `RebuildVerification`, whose identity/version are fingerprinted while its
  application-owned transaction closure is not;
- `validateProjectionCatalog`, `useProjectionCatalog`, and
  `useProjectionCatalogM`;
- `ValidatedProjectionCatalog`, whose constructor is hidden;
- typed live selection through `typedInlineProjections`;
- deterministic inventory, registration, replay-metadata, fingerprint, and
  rendering selectors; and
- `compareCatalogBaseline`, which reports declarations present in an earlier
  inventory but absent from a new one without conflating removal detection with
  single-catalog validity.

Validation is pure and closed-world. It can prove ownership, reference,
ordering, group, source, and replay-policy consistency for declarations in the
catalog. It cannot inspect a `Hasql.Transaction.Transaction`, discover an
undeclared application table, or prove which table arbitrary SQL writes.
Application DDL, migrations, codecs, and handler bodies remain application
owned.

`unmanagedInlineProjections`, `unmanagedAsyncProjection`, and
`unmanagedReadModel` are explicit compatibility labels for existing callers.
They preserve the wrapped value but do not imply catalog validation.

## `Keiro.Projection.Catalog.Operations`

Types and functions:

- opaque `ProjectionCatalogOperations` and `projectionCatalogOperations`;
- `CatalogInventoryReport` and `catalogInventoryReport`;
- `RebuildPreview` and `previewGroupRebuild`;
- `RegisteredRebuildPreview` and `previewRegisteredGroupRebuild`;
- `CatalogRunReport` and `CatalogOpsError`;
- `startGroupRebuild`;
- `inspectGroupRebuild`;
- `resumeGroupRebuild`; and
- `abandonGroupRebuild`.

Inventory and pure preview derive every fact from one
`ValidatedProjectionCatalog`; registered preview performs only a lifecycle
read and reports whether its fingerprint matches. Inspection rejects runs owned
by a different catalog. Start, resume, and abandon are explicit mutations over
the catalog replay runner. The module exposes versioned JSON values but
deliberately contains no CLI parser, renderer, confirmation rule, or connection
configuration.

## `Keiro.Connection`

Types and functions:

- `qualifyTable`
- `quoteIdentifier`
- `withProjectionSchema`
- `keiroConnectionSettings`
- `ensureProjectionSchema`

Use it to keep application-owned projection tables outside the `kiroku` and
`keiro` framework schemas. Prefer schema-qualified SQL; the connection helpers
can additionally add an application schema to Kiroku's `extraSearchPath`
without changing the event-store schema or notification channel.

## `Keiro.ReadModel`

Types and functions:

- `ReadModel (..)`
- `qualifiedTableName`
- `ConsistencyMode (..)`
- `StrongScope (..)`
- `PositionWaitOptions (..)`
- `defaultStrongWaitOptions`
- `ReadModelError (..)`
- `runQuery`
- `runQueryWith`
- `waitFor`
- `subscriptionPositionFromInventory`
- `readSubscriptionPosition`
- `storeHeadPosition`
- `categoryHeadPosition`
- re-exports from `Keiro.ReadModel.Schema`.

Use it to define typed query wrappers and consistency behavior.

`subscriptionPositionFromInventory` and `readSubscriptionPosition` take the
minimum durable checkpoint across every member with the exact subscription
name. `storeHeadPosition` uses the store cursor captured by Kiroku's public
one-statement inventory, rather than inferring the head from the newest visible
event.

## `Keiro.ReadModel.Schema`

Types and functions:

- `ReadModelMetadata (..)`
- `ReadModelStatus (..)`
- `registerReadModel`
- `lookupReadModel`
- `markRebuilding`
- `markLive`
- `markAbandoned`
- `transitionReadModelTx`

Use it for metadata initialization and rebuild lifecycle coordination.

## `Keiro.ReadModel.Rebuild`

Types and functions:

- `RebuildRunId`, `RebuildRequest`, and `RebuildFailure`
- `GroupLifecycleStatus` and `GroupRebuildMetadata`
- `CatalogRegistrationError`, `RebuildStartError`, and `GroupTransitionError`
- opaque `GroupRebuildHandle` and `GroupCompletionToken`
- `GroupPreparation`
- `registerProjectionCatalog`
- `lookupProjectionRebuildGroup`
- `beginGroupRebuild`
- `finishGroupRebuild`
- `abandonGroupRebuild`
- `RebuildOptions` and `defaultRebuildOptions`
- `CatalogRebuildError` and `RebuildRunStatus`
- `RebuildRunReport`, `RebuildSourceProgress`, `RebuildAdapterProgress`, and
  `RebuildVerificationProgress`
- `startCatalogRebuild`
- `resumeCatalogRebuild`
- `inspectCatalogRebuild`
- `abandonCatalogRebuild`
- `RebuildError (..)`
- `startRebuild`
- `finishRebuild`
- `rebuild`
- `promote`
- `abandonRebuild`

The catalog group API is the managed rebuild boundary. Preparation derives its
targets and framework reset identities only from a validated catalog, and
promotion requires an opaque completion token from the replay runner. The
runner captures an immutable Kiroku head, globally merges category pages,
commits target writes with durable progress, enforces exact-fingerprint resume,
and promotes only complete source/adapter/verification evidence. The
single-read-model functions are an unmanaged compatibility path;
`rebuild` and `promote` are only low-level status transitions.

## `Keiro.ProcessManager`

Types and functions:

- `ProcessManager (..)`
- `DomainProcessManager (..)`
- `ProcessManagerAction (..)`
- `ProcessManagerResult (..)`
- `DomainProcessManagerResult (..)`
- `PMCommand (..)`
- `PMCommandResult (..)`
- `DomainPMCommandResult (..)`
- `PMStateResult (..)`
- `PoisonPolicy (..)`
- `RejectedCommandPolicy (..)`
- `DispatchFailure (..)`
- `WorkerOptions (..)`
- `defaultWorkerOptions`
- `isTransientStoreError`
- `isTransientCommandError`
- `isRejectionClass`
- `decideForFailures`
- `ackForCommandError`
- `deterministicCommandId`
- `eventAlreadyIn`
- `confirmBenignDuplicate`
- `runProcessManagerOnce`
- `runProcessManagerWorkerWith`
- `runProcessManagerWorker`
- `runDomainProcessManagerOnce`
- `runDomainProcessManagerWorkerWith`
- `runDomainProcessManagerWorker`

Use it for event-sourced coordination across streams. `eventAlreadyIn` is the
idempotency point-lookup pre-check, exported so routers and other callers can
reuse it. `runProcessManagerWorkerWith` accepts `WorkerOptions` for
poison-message policy, transient retry delay, and dispatch metrics; the default
worker finalizes each ack exactly once, retries transient store failures, and
halts deterministic failures.
`ProcessManager.targetProjections` is a list of inline projections for target
events only; `[]` preserves append-only dispatch, while a non-empty list gives
read-your-own-writes for target read models updated by process-manager dispatch.
The projections should be small, deterministic writes for the target aggregate's
own read model, not a replacement for async projections or process-manager state
projection.
`RejectedHalt` is the safe default for target rejections. `RejectedDeadLetter`
persists a dispatch witness before acknowledging, while `RejectedSkip`
acknowledges without one. `confirmBenignDuplicate` proves a duplicate event id
belongs to the intended target stream before it is treated as success.

`DomainProcessManager` keeps the manager's own state/timer path unchanged and
uses a `DomainCommandHandler` for target commands. A handled accepted,
rejection, or no-op appears as `DomainPMCommandHandled`; a confirmed accepted
redelivery is `DomainPMCommandDuplicate`, and a genuine `CommandError` is
`DomainPMCommandFailed`. A duplicate cannot reconstruct the original in-memory
event batch. Domain workers acknowledge typed rejection/no-op as `AckOk` and
bypass `RejectedCommandPolicy`.

Detailed one-shot results retain every handled payload and therefore use
memory proportional to accepted batches returned across the fan-out. Worker
entry points instead summarize each target strictly into only duplicate/failure
information and release handled payloads before dispatching the next target.

## `Keiro.Router`

Types and functions:

- `Router (..)`
- `RouterResult (..)`
- `DeclarativeRouter (..)`
- `DeclarativeRouterResult (..)`
- `RouterSelectionContract (..)`
- `RouterSelectionFailure (..)`
- `RecipientLimit`, `mkRecipientLimit`, `recipientLimitValue`
- `SelectionIdentity (..)`, `SelectionVersion`, `mkSelectionVersion`,
  `selectionVersionValue`, `SelectionFingerprint (..)`
- `SelectionOrder (..)`, `SelectionDedupe (..)`, `RedeliveryPolicy (..)`,
  `PartialDispatchPolicy (..)`, `EmptySelectionPolicy (..)`,
  `SelectionFailurePolicy (..)`
- `normalizeRecipients`
- `emptySelectionDeadLetterReason`, `selectionFailureDeadLetterReason`
- `DomainRouter (..)`
- `DomainRouterResult (..)`
- `runRouterOnce`
- `runRouterWorkerWith`
- `runRouterWorker`
- `runDeclarativeRouterOnce`
- `runDeclarativeRouterWorkerWith`
- `runDeclarativeRouterWorker`
- `runDomainRouterOnce`
- `runDomainRouterWorkerWith`
- `runDomainRouterWorker`
- `deterministicRouterCommandId`

Use it for stateless, effectful fan-out (content-based router / recipient list).
Unlike a process manager, a router resolves its targets *effectfully* (for
example from a read-model `runQuery`) rather than purely from manager state, and
keeps no state stream. `Router.targetProjections` has the same target-only
meaning as the process-manager field: use `[]` for the migration/default path,
or pass the target aggregate's inline projections when router-dispatched writes
must update target read models in the append transaction. `runRouterWorkerWith`
uses the same `WorkerOptions` as process-manager workers. Re-exported from
`Keiro`.

The domain router has the same handled/duplicate/failure distinction and
bounded worker retention as the domain process manager. Target resolution
order, target-identity deterministic ids, legacy-id duplicate compatibility,
and one transaction per target are unchanged. Eventless rejection/no-op leaves
no event id, so redelivery evaluates it again.

`DeclarativeRouter` places a closed selection contract around an
application-owned typed query seam. `runDeclarativeRouterOnce` distinguishes
failed, empty, and dispatched selection outcomes. Before dispatch it sorts by
physical target stream, collapses exact duplicate commands, rejects conflicting
commands for one stream, and enforces a positive post-deduplication
`RecipientLimit`. The worker maps empty and selection-failure outcomes through
their independent closed policies. Generated candidate Language 5 routers use
this surface; the existing `Router` remains the arbitrary effectful fallback.

See [Routers And Effectful Fan-Out](../guides/routers-and-effectful-fan-out.md)
for the DSL syntax, failure-policy matrix, stable-union semantics, and rollout
rules.

## `Keiro.Timer`

Types and functions:

- `TimerId (..)`
- `TimerRequest (..)`
- `TimerRow (..)`
- `TimerStatus (..)`
- `scheduleTimerTx`
- `scheduleTimerOnceTx`
- `claimDueTimer`
- `markTimerFired`
- `countDueTimers`
- `countStuckTimers`
- recovery: `StuckTimerFilter (..)`, `anyStuckTimer`, `findStuckTimers`,
  `requeueStuckTimers`, `requeueStuckTimer`, `cancelTimer`, `deadLetterTimer`
- worker: `TimerWorkerOptions (..)`, `TimerWorkerConfigError (..)`,
  `defaultTimerWorkerOptions`, `mkTimerWorkerOptions`, `runTimerWorker`,
  `runTimerWorkerWith`

Use it for durable timer storage and polling workers. `runTimerWorker` is
`runTimerWorkerWith` at `defaultTimerWorkerOptions`; both take an opt-in
`Maybe KeiroMetrics` as their first argument. The recovery group is the supported
stuck-row runbook — see
[Operations](operations.md#stuck-row-recovery-runbook).

## `Keiro.Workflow` and the workflow module family

The durable-execution runtime. It is **not** re-exported from `Keiro`; import the
modules directly, the same way you import `Keiro.Timer` or `Keiro.Outbox`.

- `Keiro.Workflow` — the `Workflow` effect, `step`, `awaitStep`, `patch`,
  `continueAsNew`, `restoreSeed`, `runWorkflow`, `runWorkflowWith`,
  `WorkflowRunOptions (..)`, `defaultWorkflowRunOptions`, `WorkflowOutcome (..)`,
  the journal codec (`workflowJournalCodec`, `WorkflowJournalEvent (..)`), and
  `workflowStreamName`.
- `Keiro.Workflow.Sleep` — `sleepNamed` / `sleep` and `runWorkflowTimerWorker`.
- `Keiro.Workflow.Awakeable` — `awakeableNamed` / `awakeable`,
  `deterministicAwakeableId`, `signalAwakeable`, `cancelAwakeable`.
- `Keiro.Workflow.Child` — `spawnChild`, `awaitChild`, `cancelChild`.
- `Keiro.Workflow.Resume` — `resumeWorkflowsOnce`, `runWorkflowResumeWorker`,
  `runWorkflowResumeWorkerPush`, `WorkflowResumeOptions (..)`,
  `defaultWorkflowResumeOptions`, `WorkflowRegistry`, `WorkflowDef (..)`,
  `ResumeSummary (..)`.
- `Keiro.Workflow.Instance` — instance rows, lease state, and the supported
  operator recovery API `resurrectFailedWorkflow`.
- `Keiro.Workflow.Snapshot` — `workflowStateCodec`, the fixed-shape-hash snapshot
  discriminant for the accumulated step-result map.
- `Keiro.Workflow.Types` — `WorkflowName`, `WorkflowId`, `StepName`, `PatchId`,
  `AwakeableId`, `ChildHandle`, and the reserved step-name prefixes.
- `Keiro.Workflow.Gc` — `WorkflowGcPolicy (..)`, `WorkflowGcSummary (..)`,
  `gcWorkflowsOnce`, `runWorkflowGcWorker`: the operator-scheduled retention
  sweep over terminal instances.
- `Keiro.Workflow.Schema`, `.Awakeable.Schema`, `.Child.Schema` — the SQL layer
  over `keiro_workflows`, `keiro_workflow_steps`, `keiro_awakeables`, and
  `keiro_workflow_children`, for operational tooling.

Use it for long-running processes that read as one function with in-line waits.
See [Durable Workflows](durable-workflows.md) for the authoring surface and the
[guide](../guides/durable-workflows.md) for a worked example.

## `Keiro.Wake`

Types and functions:

- `WakeSignal (..)` — a newtype over its one field,
  `waitForWake :: Int -> IO WakeReason` (the argument is the fallback timeout in
  microseconds)
- `WakeReason (..)` — `WokenByNotify` or `WokenByTimeout`
- `wakeSignalFromStore`
- `neverWake`

Use it to replace a worker's fixed poll sleep with "wait until an append
notification arrives or a fallback timeout elapses". It duplicates the broadcast
channel of Kiroku's existing per-store listener, so push adds no new database
connections, and the fallback keeps correctness on a dropped notification.

## `Keiro.Subscription.Shard`

Types and functions:

- `WorkerId (..)`, `freshWorkerId`
- `acquireOwnedBuckets`, `renewOwnedBuckets`, `relinquish`
- `ensureShards`, `ownershipSnapshot`
- `Keiro.Subscription.Shard.Worker` adds `runShardedSubscriptionGroup`
- `Keiro.Subscription.Shard.Schema` holds the `keiro_subscription_shards` SQL

Use it to run a pool of identical workers over one Kiroku consumer group: each
bucket is leased, so the pool re-divides automatically when a worker joins,
leaves, or dies, with no external coordinator.

## `Keiro.DeadLetter`

Types and functions:

- `DispatcherKind (..)`
- `DispatchDeadLetter (..)`
- `DispatchDeadLetterRecord (..)`
- `recordDispatchDeadLetter`
- `listDispatchDeadLetters`

Use it to persist and inspect process-manager/router target rejections when a
worker deliberately selects `RejectedDeadLetter`.

## `Keiro.DeadLetter.Replay`

Types and functions:

- `ReplayOutcome (..)`
- `ReplayResult (..)`
- `DeadLetterRecord (..)`
- `listSubscriptionDeadLetters`
- `replaySubscriptionDeadLetters`

Use it for repeatable operator replay of Kiroku subscription dead letters. The
caller supplies domain decoding/handling and classifies fresh versus duplicate
work; stored rows are retained.

## `Keiro.Integration.Event`

The canonical cross-context integration-event envelope. Exports the envelope
type, `IntegrationContentType (..)`, `SchemaReference (..)`, `TraceContext (..)`,
`IntegrationEventError (..)`, `encodeJsonIntegrationEvent`,
`decodeJsonIntegrationEvent`, `integrationPayload`, `integrationHeaders`, the
`header*` Kafka-header name constants, `contentTypeText`, and `parseContentType`.

Use it to construct and serialize events published across bounded contexts.

## `Keiro.Outbox`

Transactional outbox. Re-exports `Keiro.Outbox.Types` and exports
`enqueueOutboxTx`, `claimOutboxBatch`, `markOutboxSent`,
`lookupOutbox`, `listOutbox`, `freshOutboxId`, `enqueueIntegrationEventTx`,
`IntegrationProducer (..)`, `IntegrationEventDraft (..)`, `mintIntegrationEvent`,
`draftToEvent`, `enqueueProducerEventTx`, `PublishOutcome (..)`,
`publishClaimedOutbox`, `outboxMaintenancePass`, and `sampleOutboxBacklog`.
`IntegrationProducerConfigError (..)`, `mkIntegrationProducer`,
`requeueStuckOutbox`, `countOutboxBacklog`, and `garbageCollectSent` complete the
surface. `Keiro.Outbox.Kafka` adds the Kafka producer adapter.

Use it to commit side-effect intents in the write transaction and publish them
asynchronously with per-key ordering, backoff, dead-lettering, and a separate
maintenance pass for crashed-worker reclamation and backlog sampling.

## `Keiro.Inbox`

Idempotent inbox. Re-exports `Keiro.Inbox.Types` and exports
`lookupInbox`, `listInbox`, `garbageCollectCompleted`, `countInboxBacklog`,
`sampleInboxBacklog`, `markFailedTx`, `runInboxTransaction`,
`runInboxTransactionWithKey`, `runInboxTransactionWith`,
`runInboxTransactionBatch`, and the bounded-retry family
(`runInboxTransactionWithRetries`, `runInboxTransactionWithRetriesWith`,
`runInboxTransactionWithRetriesKey`). `Keiro.Inbox.Kafka` adds the Kafka consumer
adapter.

Use it to deduplicate inbound integration events by `(source, dedupe_key)`.

## `Keiro.Telemetry`

OpenTelemetry instrumentation. Exports span helpers, W3C trace-context
propagation, semantic-convention attribute-name constants, `KeiroMetrics`,
`newKeiroMetrics`, and `record*` helpers for the `keiro.*` metric instruments.
Process-manager and router workers can record `keiro.dispatch.failed`,
`keiro.dispatch.duplicates`, and `keiro.dispatch.poison` through
`WorkerOptions.metrics`.

Outcome-aware command spans add `keiro.command.decision`, whose complete value
set is `accepted`, `rejected`, and `no_op`. The
`keiro.command.decisions` counter uses the same bounded dimension. Application
rejection/no-op payloads are never labels, error classes, span descriptions, or
dead-letter reasons, and typed rejection/no-op keeps successful span status.

The preferred projection gauge is
`keiro.projection.global_position_distance` with unit `{position}`. The
historical `keiro.projection.lag` gauge remains a deprecated 0.11 compatibility
instrument and receives the same value. Neither value counts relevant events.

## `Keiro.Ops` (package `keiro-ops`)

Embeddable and standalone operational command tree. The database-only surface
includes `stream subscriptions`, which returns the captured Kiroku store
position plus every durable checkpoint in subscription/member order, and
`projection position --subscription NAME`, which returns matching `members`
plus `minimum_checkpoint_position` and
`maximum_global_position_distance`. Missing subscriptions have an empty member
array and null summaries. Both commands are read-only, use
`subscriptionCheckpointInventory`, and are available without an `AppHooks`
capability.

## `Keiro.ReplayAudit`

Read-only real-log replay gate. Exports:

- `AuditMode (..)` — `AuditFull` and affected-event `AuditTargeted`, plus
  `AffectedSet`
- `AuditBudget (..)` / `defaultAuditBudget` — resumable scan controls
- `AuditTarget (..)`, `SomeAuditTarget (..)`, `streamInCategory` — typed targets
- `AuditOutcome (..)` (`ReplayOk` / `ReplayFailed` / `SeedDivergence`),
  `StreamAuditResult (..)`, `AuditReport (..)`
- `auditStream`, `auditStreams`, `renderAuditReport`, and `auditExitCode`
  (`0` clean, `1` on any failure or divergence)

Generated DSL services expose one context-wide
`Generated.<Context>.ReplayAudit.auditTargets` assembly.

## `Keiro.Migrations` (package `keiro-migrations`)

Native `pg-migrate` component and the standard `keiro-migrate` executable.
Exports `keiroMigrations` and `frameworkMigrationPlan`.
`Keiro.Migrations.History.Codd` exports the exact legacy evidence and combined
Kiroku/Keiro import mapping used during cutover.

Use it to compose Kiroku first and Keiro second, apply or strictly verify the
plan, and import an existing shared Codd ledger without replaying SQL.

## `Keiro.PGMQ.*` (package `keiro-pgmq`)

Postgres-native work queues over PGMQ, used by DSL `workqueue` / `dispatch`
nodes and available directly:

- `Keiro.PGMQ` — the umbrella module.
- `Keiro.PGMQ.Job` — `Job (..)`, `RetryPolicy (..)`, `defaultRetryPolicy`,
  `mkRetryPolicy`, `JobPolling (..)`, `JobOrdering (..)`, `JobTuning (..)`, and
  the job runner.
- `Keiro.PGMQ.Codec` — `aesonJobCodec` (raw) and `keiroJobCodec` (the versioned
  `{v,t,data}` envelope whose `JobPayloadFromFuture` result drives the
  workers-before-producers rollout rule).
- `Keiro.PGMQ.Dlq` — dead-letter queue provisioning and `redriveDlq`.
- `Keiro.PGMQ.Runtime` / `Keiro.PGMQ.Metrics` — worker wiring and instruments.

See [Work Queues](work-queues.md) for the authoring and operations reference,
and [Deploy Ordering](deploy-ordering.md#3-upgrade-versioned-job-workers-before-producers)
for the queue-payload rollout rules.

## `Keiro.Dsl.*` (package `keiro-dsl`)

The library exposes the grammar, parser, pretty-printer, validator, type graph,
surface-aware `SemanticImpact` model, compatibility-vector differ and JSON report, coverage inventory, historical
codec-comparison engine, binding-obligation report, scaffolder,
planner/runner, manifest, starter skeleton, and harness modules. In particular,
`Keiro.Dsl.TypeGraph`, `Keiro.Dsl.SemanticImpact`, `Keiro.Dsl.Coverage`, `Keiro.Dsl.CodecCompare`, and
`Keiro.Dsl.ExplainBindings` are public library surfaces for tooling and
consumer-compiled migration tests. `Keiro.Dsl.Expression` exposes the checked
version-2 scalar resolver and its typed roots, required projections, literals,
arithmetic evidence, and stable expression diagnostics; consumers should use
that resolver rather than reconstructing capability rules from the raw grammar
AST.

`Keiro.Dsl.ConsumerTypePlan` is the codec-agnostic lowering authority for a
checked mapped `ResolvedTypeExpr`. It returns the consumer-facing Haskell type
occurrence, deterministic import requirements, and transitive mapped
dependencies. Queue and read-model generators compose their own JSON or SQL
policy around this plan rather than reconstructing type rendering.

Candidate language 5 adds projection-target, rebuild-group, projection-owner,
query-binding nodes, typed workqueue fields, and atomic read-model query
input/result clauses. Queue payload modules and read-model query-contract
modules lower those mapped expressions through `ConsumerTypePlan` and the
shared codec planner. `Keiro.Dsl.ProjectionMappedImpact` derives typed inline
and aggregate-catalog consumers only from authoritative private-event roots and
keeps groups, targets, observing read models, and heterogeneous sources in a
separate operational relation. `Keiro.Dsl.Scaffold` lowers the checked catalog into
one `Generated.<Context>.ProjectionCatalog` facade backed by
`Keiro.Projection.Catalog` and `Keiro.ReadModel.Rebuild`. The facade exports the
validated catalog, deterministic inventory and registration views, typed
inline projection sets, and group-scoped rebuild starters. Its paired
`<Context>.ProjectionCatalog.ProjectionCatalogHoles` file is create-once and
contains application-owned live/replay apply, category decode, and idempotency
functions. `Keiro.Dsl.Diff`, `Keiro.Dsl.ReplayImpact`, scaffold records, and
workspace records expose the same stable catalog identities; consumers should
not reconstruct a second inventory from generated module names.

Most applications use the executable instead: `parse`, `check`, `scaffold`,
`diff --since`, and `new <kind>`. The newer opt-in workflows include
`check --explain-bindings`, `check|diff --coverage-report`,
`diff --gate|--explain|--report-out`, and
`scaffold --codec-comparison ... --comparison-out ...`. See
[Typed Specifications](typed-spec-toolchain.md).

## `Keiro.Prelude`

Project prelude used by Keiro modules. Application code may import it when
following the repository's style, but it is not required to use Keiro.
