# Offline Projection Rebuilds

Keiro's catalog rebuild is offline for one projection group: it fences that
group's writers, takes its query models out of service, rebuilds to one captured
event-log head, verifies the result, and only then returns the whole group to
`live`. Other independent catalog groups can continue operating.

Use this lifecycle when projection code or shape changes, derived data is
damaged, a new target must be populated from retained history, or several
related targets must be reconstructed and promoted as one unit. Keiro does not
provide a built-in shadow-table or online cutover mechanism.

The runnable example is the `jitsurei-order-reporting` group declared in
[`Jitsurei.ReadModels`](../../jitsurei/src/Jitsurei/ReadModels.hs). Its operator
commands are covered in
[Run And Operate Jitsurei](run-and-operate-jitsurei.md#rehearse-a-catalog-rebuild).

## What "Offline" Means

Once preparation commits:

- `runCommandWithCatalogProjections` returns `ProjectionCommandFenced`; its
  event append and inline target writes roll back together.
- `applyAsyncProjectionFromCatalog` returns `CatalogAsyncFenced` before writing
  a dedup key or target row. The worker must not advance its checkpoint.
- catalog-bound queries fail their lifecycle check instead of reading partial
  state.
- the selected group remains unavailable across process crashes and operator
  handoffs because its lifecycle and run progress are durable.

This protection applies only to catalog-aware paths. The compatibility inline
runners and router/process-manager `targetProjections` do not acquire the group
fence. Before rebuilding, stop those writers or provide equivalent exclusion.
Do not start an offline rebuild while an undeclared write path can still mutate
one of its targets.

## Model The Rebuild Before Running It

A rebuild derives all of its behavior from one `ValidatedProjectionCatalog`:

- `RebuildGroupDeclaration.orderedTargets` defines the atomic unit and target
  dependency order.
- Each `TargetDeclaration` chooses `ClearBeforeReplay` or
  `PreserveAndReconcile`.
- Each `ProjectionDefinition` chooses `Replayable adapter` or
  `LiveOnly reason` independently from target reset policy.
- `SourceDeclaration` selects a category or all-stream replay and records its
  codec fingerprint.
- Async handlers refer to declared subscription and dedup identities.
- `RebuildVerification` transactions hold application-owned proofs that must
  pass before promotion.

The replay adapter is deliberately separate from the live handler. It must
perform only reconstructible database work: never repeat notifications,
integration calls, or other live-only behavior during historical replay.
Verification transactions must be read-only checks of rebuilt state.

`ClearBeforeReplay` is appropriate only when retained history and the replay
adapter can reconstruct the target. Use `PreserveAndReconcile` for brownfield
roots, incomplete history, or rows with non-event provenance. Verification must
then prove that retained and replayed data agree.

## Preview First

Construct the operator-neutral operations value from the exact catalog mounted
by the application:

```haskell
operations :: ProjectionCatalogOperations
operations = projectionCatalogOperations validatedCatalog

previewGroupRebuild operations reportingGroupId
previewRegisteredGroupRebuild operations reportingGroupId
```

The pure preview reports target order, clear/preserve policy, sources,
projection owners, query bindings, subscription and dedup resets, verification
hooks, lock scope, slice fingerprint, and whether preparation is destructive.
The registered preview adds the current durable lifecycle and whether its slice
matches the current catalog. Neither call fences writers or changes data.

Before proceeding:

1. Apply the service migration for the new application-owned target shape.
2. Register the validated catalog and resolve any catalog adoption drift.
3. Ensure every declared async subscription has its expected durable member
   rows. Keiro will not invent missing consumer-group members.
4. Stop or exclude every unmanaged writer to a target in the group.
5. Test replay adapters and verification against a disposable database.
6. Take any backup required by the service's recovery policy, especially before
   clearing a target whose source history may have been retained incompletely.
7. Choose a stable, unique `RebuildRunId`, operator identity, reason, and replay
   cursor.

## Start The Catalog Rebuild

The library entry point accepts only the operations value, group identity, and
runner options. Callers cannot substitute their own target, reset, source, or
handler lists:

```haskell
let request =
      RebuildRequest
        { rebuildRunId = runId
        , requestedBy = "read-side-operator"
        , requestReason = "rebuild order reporting v2"
        , replayFrom = GlobalPosition 0
        }
    options =
      (defaultRebuildOptions request)
        { replayPageSize = 500
        , rebuildMetrics = Just metrics
        }

startGroupRebuild operations reportingGroupId options
```

`startGroupRebuild` drives preparation, replay, verification, and promotion. It
may therefore be a long-running call. The default page size is 500; each page is
bounded and its target changes and progress evidence commit together.

Preparation is one transaction under the group's exclusive lock. It:

1. marks the group and its bound query models as rebuilding;
2. truncates every `ClearBeforeReplay` target through one multi-table statement
   derived from the declared dependency order, without `CASCADE`;
3. leaves `PreserveAndReconcile` targets untouched;
4. deletes dedup rows only for replayable async handlers in the group; and
5. resets every persisted member of each declared replayable subscription to
   `replayFrom` through Kiroku's public checkpoint API.

If a declared subscription has no durable member row, the whole preparation
transaction rolls back: the fence, target clears, dedup deletion, and any
checkpoint resets do not partially commit. An undeclared foreign-key reference
likewise makes the non-`CASCADE` truncate fail and rolls back preparation rather
than erasing an external table.

After the fence is durable, the runner captures one immutable store head. It
then reads each declared category or `AllStreams` source from `replayFrom` to
that head. Distinct category pages are merged by global position so adapters
observe deterministic global order. Events appended after the captured head
are outside this run.

Each event is evaluated by every replay adapter for its source. An adapter can
classify it as irrelevant, apply it, or return a typed decode failure. Both
irrelevant and applied events advance durable replay evidence. A decode failure
rolls back the current page, records source, projection, and position evidence
without storing the payload, and keeps the group fenced.

## Verification And Promotion

After every source proves exhaustion through the captured head, the runner
executes all declared verification transactions. A failure records its stable
verification identity and detail and leaves the run resumable and the group
fenced.

Promotion requires complete source, adapter, and verification evidence. For
async handlers it also reconstructs redelivery safety from each subscription's
durable floor through the captured head. One final transaction:

- backfills dedup identities in bounded batches;
- advances every declared subscription member to the captured head;
- records the completion proof;
- marks bound query models live; and
- returns the group to `live`.

If a declared checkpoint row disappears before promotion, that transaction
rolls back and the typed
`CatalogRebuildPromotionCheckpointsMissing` error leaves the run fenced and
resumable. After successful promotion, a live worker redelivering an event from
the covered window receives `CatalogAsyncDuplicate` rather than applying it
again.

## Inspect, Repair, And Resume

Inspect durable progress at any time:

```haskell
inspectGroupRebuild operations runId
```

The report includes the captured head, run status, source cursors, adapter
evaluation/application counts, and verification evidence. It does not contain
raw event payloads.

After repairing an application-owned decode, SQL, retained-row, or verification
problem, resume the same run:

```haskell
resumeGroupRebuild operations runId options
```

Resume continues from committed progress and keeps the original captured head.
The page size may change, but the catalog group slice, source and codec facts,
adapter order, verification identities, and runner contract must match the
stored run before another handler executes. A genuine contract change requires
an explicit recovery decision rather than silently continuing with different
semantics.

Use `abandonGroupRebuild` only when the run must become terminal. Abandonment
records structured failure evidence and deliberately leaves the group and its
queries unavailable. It does not restore cleared data or undo committed replay
pages.

## Rehearse With Jitsurei

The embedded example operator makes mutation an explicit two-step action. A
command without `--force` previews and exits unsuccessfully; repeat the rendered
invocation with `--force` only after reviewing it:

```bash
cabal run jitsurei-demo -- ops rebuild preview \
  jitsurei-order-reporting --json

cabal run jitsurei-demo -- ops rebuild start \
  jitsurei-order-reporting \
  --run-id guide-rebuild-1 \
  --requested-by guide \
  --reason "offline rebuild rehearsal"

cabal run jitsurei-demo -- ops rebuild start \
  jitsurei-order-reporting \
  --run-id guide-rebuild-1 \
  --requested-by guide \
  --reason "offline rebuild rehearsal" \
  --force

cabal run jitsurei-demo -- ops rebuild status \
  guide-rebuild-1 --json
```

Run this only against the disposable Jitsurei database described in
[Run And Operate Jitsurei](run-and-operate-jitsurei.md). The standalone
`keiro-ops` binary cannot discover application handlers; the application binary
must mount its exact `ProjectionCatalogOperations` value.

## Legacy Single-Model Offline Rebuild

`Keiro.ReadModel.Rebuild` retains an unmanaged compatibility lifecycle for an
existing single read model:

1. `startRebuild model projectionNames replayFrom` fences the legacy model,
   truncates its one table, clears the named dedup rows, and resets its
   subscription members.
2. Replay with `applyAsyncProjectionUnfenced`; never use that function in a live
   worker.
3. Run application verification, then call
   `finishRebuild model projectionNames replayFrom`.
4. Call `abandonRebuild` on failure and keep the partial model unavailable.

This path accepts caller-supplied projection names and cannot coordinate
several targets, query bindings, sources, verification hooks, or group-wide
promotion. Keep it only while migrating existing applications. New production
code should use a validated catalog and the group lifecycle above. The
lower-level `rebuild` and `promote` status functions bypass reset and promotion
safeguards and are not a complete rebuild workflow.

## Offline Rebuild Checklist

- The exact application catalog is registered and its slice matches.
- Every target writer is catalog-aware or stopped.
- Target migrations and recovery backups are complete.
- Replay adapters omit live-only effects.
- Every async subscription member exists before preparation.
- The preview's destructive actions and reset scope were reviewed.
- Fenced command, worker, and query outcomes are treated as unavailable—not as
  success.
- Failures are inspected and repaired before resuming the same run.
- Abandonment is understood to preserve the fence rather than restore data.
