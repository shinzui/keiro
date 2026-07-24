# Deploy Ordering

Events, queued jobs, timer payloads, integration messages, and workflow step
results can outlive the binary that wrote them. A safe rollout therefore asks:
which binaries can read what every other binary may write during the deployment
window? The narrative treatment is in
[Evolution And Replayability](../guides/evolution-and-replayability.md#deploy-ordering-rules);
this page is the operator-facing reference.

Three terms recur below. **Roll-forward-only** means that after the new version
writes its first durable value, an old binary cannot read that value, so rollback
means restore from backup rather than redeploy old code. A **drain** pauses the
subscription or queue and lets in-flight work finish before binaries switch. A
**redelivery window** is the period in which already-processed input can arrive
again because of a crash before checkpoint, a visibility timeout, or a consumer
rebalance.

## 1. Start From The Durable Boundary

Inventory every durable value whose decoder or decision logic changes. Include
aggregate events, process-manager saga events, queued jobs, pending timers,
integration-event backlogs, and workflow journals. A rollout is safe only when
every binary that may see each value can decode it and interpret it compatibly.
Source-compatible Haskell changes are not enough.

If this rule is skipped, the observable failure occurs after deployment on the
first old value or cross-version write: hydration fails, a worker retries or
dead-letters, or replay silently derives different state.

## 2. Cut Aggregate Codec Bumps Over Without Mixed Versions

An aggregate `Codec` has one `schemaVersion`, used both as the version written
now and as the decode target. It cannot decode version N while continuing to
write N-1. Once a new replica appends the first version-N event, an N-1 replica
returns `VersionAhead` while hydrating any stream containing that event. A new
event type has the analogous `UnknownEventType` failure on old replicas.

Use a stop-the-world cutover or blue/green cutover for an aggregate codec bump.
In a blue/green cutover, keep one version exclusively responsible for a stream
category and switch traffic atomically; do not let old and new writers share
the category. After the first new-version append, the deployment is
roll-forward-only. A two-phase capability that could decode N while still
writing N-1 does not exist today.

The behavior comes from
[`Keiro.Codec`](../../keiro-core/src/Keiro/Codec.hs): a stored version above the
codec's target returns `VersionAhead`.

If this rule is violated, old replicas fail command hydration with
`HydrationDecodeFailed (VersionAhead ...)`; redeploying the old release does not
recover streams that already contain new-version events.

## 3. Upgrade Versioned Job Workers Before Producers

`keiroJobCodec` wraps each PGMQ body as `{v,t,data}` and returns
`JobPayloadFromFuture` when an old worker reads an envelope written by a newer
producer. The job runner retries that result after
`RetryPolicy.defaultRetryDelay`. Those retries consume delivery attempts, so
size `maxRetries * defaultRetryDelay` to cover the rollout window. The default
policy is five deliveries with a 60-second delay.

Deploy workers that understand the new job version first, wait until all old
workers are gone, and only then deploy producers that emit it. Generated
workqueues start with a schema-version-1 `QueueCodec` backed by
`keiroJobCodec`. Never change a non-empty queue directly between bare
`aesonJobCodec` payloads and the `{v,t,data}` envelope; drain it first or use a
temporary decoder that accepts both shapes.

See [Work Queues](work-queues.md#payload-codecs-and-evolution),
[`Keiro.PGMQ.Codec`](../../keiro-pgmq/src/Keiro/PGMQ/Codec.hs), and
[`RetryPolicy`](../../keiro-pgmq/src/Keiro/PGMQ/Job.hs).

If this rule is violated, future-version bodies burn through retries and reach
the dead-letter queue; changing envelope shape without a drain makes old
in-flight bodies fail as `JobPayloadMalformed`.

## 4. Drain Process-Manager And Router Decide Changes

Process managers and routers derive deterministic target-command event ids from
the source event and target identity. On redelivery, a target command already
written under that id is confirmed as a benign duplicate and skipped. If a
deployment changes fan-out while old source events remain in the redelivery
window, the old and new fan-outs can therefore merge silently: overlapping
targets deduplicate while only the newly selected targets run.

Pause the subscription, let in-flight reactions finish, resolve or explicitly
discard its dead letters, deploy the decide change, and then resume. Apply this
procedure to changes in router resolution/dispatch, process-manager `handle`
logic, or any hand-owned hole that changes the target set. The DSL diff
emits `RouterDecideSurfaceChanged` and `ProcessDecideSurfaceChanged` advisories
for spec-visible edits. Hole-only decide changes remain invisible to the
differ, so the drain rule still applies whenever hand-owned logic changes.

The deterministic-id behavior is implemented in
[`Keiro.Router`](../../keiro/src/Keiro/Router.hs) and
[`Keiro.ProcessManager`](../../keiro/src/Keiro/ProcessManager.hs).

If this rule is violated, no error is raised: benign-duplicate confirmation
silently preserves a half-old, half-new fan-out.

## 5. Stamp Every Direct Event-Store Write

`decodeRecorded` treats absent schema-version metadata as version 1. An event
written directly to Kiroku without `encodeForAppend` or
`encodeForAppendWithMetadata` therefore becomes a version-1 payload forever,
even when its JSON was produced by current application code.

Route every aggregate append through the codec boundary. If a service must keep
a direct writer, it must reproduce the exact event-type and schema-version
metadata contract and evolve in lockstep; otherwise that stream category cannot
safely bump its codec.

See `extractSchemaVersion` in
[`Keiro.Codec`](../../keiro-core/src/Keiro/Codec.hs).

If this rule is violated, the first codec bump sends a current-shape but
unstamped payload through the version-1 upcaster chain, causing
`UpcasterError`, `DecodeFailed`, or silent payload reinterpretation.

## 6. Upgrade Timer Firers Before Scheduling New Payloads

A timer row stores its `payload` as opaque, unversioned JSON. The timer runtime
cannot upcast it. The firing function must therefore accept every payload shape
that can still be scheduled or remain pending.

Deploy all timer firers with a backward-compatible decoder first. Only after
the old firers are gone may producers schedule the new shape. Keep decoding the
old shape until every old timer has fired or been cancelled. This is the same
workers-before-producers rule as a queue, but without a version envelope to
make skew self-describing. DSL changes to the timer `payload` block emit the
`ProcessTimerPayloadChanged` advisory; hand-written payloads retain the same
manual obligation.

See [`TimerRequest`](../../keiro/src/Keiro/Timer/Types.hs) and
[`TimerWorkerOptions`](../../keiro/src/Keiro/Timer.hs).

If this rule is violated, the fire callback fails repeatedly; once attempts
exceed `TimerWorkerOptions.maxAttempts`, the timer is moved to terminal `Dead`.

## 7. Coordinate Integration Contracts Manually

`decodeJsonIntegrationEvent` is ordinary Aeson `FromJSON`; it has no envelope
upcaster or cross-repository compatibility check. The DSL can classify one
repository's contract diff, but it does not compare producer and consumer
specifications.

For an additive optional field that existing tolerant consumers ignore, deploy
the producer first and keep the consumer tolerant of both shapes. For a new
required field or any structural change, first deploy consumers that can decode
both old and new shapes, then deploy producers of the new shape, and retire the
old decoder only after the backlog drains. Bump the contract
`schemaVersion` whenever the DSL requires it. A new topic or explicit
version-dispatch path is safer for changes that cannot be dual-decoded.

See
[`decodeJsonIntegrationEvent`](../../keiro-core/src/Keiro/Integration/Event.hs).
Automated cross-service conformance remains a future initiative under
[master plan 24](../masterplans/24-close-the-evolution-and-replayability-gate-gaps-surfaced-by-the-2026-07-evolution-review.md).

If this rule is violated, the inbox consumer returns `DecodeFailed` and the
message follows its retry/dead-letter policy; changing dedupe identity can
instead admit duplicate effects.

## 8. Treat Workflow Step Results As Permanent

A workflow journal stores each named step's result as JSON and decodes it into
the type expected by the current workflow body. Never change that type in
place. Rename a changed step so it runs fresh, or protect a cross-cutting change
with a stable `patch` decision.

The resume worker defaults to five attempts. A step-result decode crash consumes
that budget and then appends `WorkflowFailed`, after which the instance is
terminally failed and leaves discovery. Deploy the corrected binary first, then
return the instance to the runnable pool with
`Keiro.Workflow.Instance.resurrectFailedWorkflow`; it resets retry and lease
state transactionally and preserves the append-only failure history. Do not
repair a failed instance with manual SQL.

See
[`Keiro.Workflow.Resume`](../../keiro/src/Keiro/Workflow/Resume.hs),
[Durable Workflows](durable-workflows.md#versioning-and-rotation), and
[Failure, retries, and resurrection](../guides/durable-workflows.md#failure-retries-and-resurrection).

If this rule is violated, resume repeatedly crashes on the journaled result and
the workflow becomes `WorkflowFailed`; recovery then requires a code fix
followed by an explicit operator-driven resurrection.

## 9. Gate Transducer Changes With Real-Log Replay

Changes to guards, outputs, writes, targets, transition modes, or fold logic can
reinterpret events already in the store. Before switching traffic, exercise
the candidate binary against a production-copy or staging database containing
representative history.

Run `keiro-dsl diff --replay-impact-out FILE`. A `replay-neutral` verdict
requires no audit. An `affected` verdict names a conservative event-type set;
run the candidate binary's `Keiro.ReplayAudit` in `AuditTargeted` mode against
a production-copy or staging database. It replays only streams containing
those types, compares snapshot-seeded state with full replay, and emits
per-stream digests. `auditExitCode` returning non-zero means do not deploy.
Reserve `AuditFull` for one-time keiki-runtime cutovers and forensics, not
routine deployments.

If this rule is violated, the next live command may fail with
`HydrationReplayFailed`; worse, an inversion-compatible change or stale snapshot
can silently derive different state.
