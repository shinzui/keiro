# Dead Letters And Replay

Keiro distinguishes two durable failure records with different meanings.

## Rejected dispatches

Process-manager and router workers default to `RejectedHalt`: a target
`CommandRejected` or `CommandAmbiguous` halts without acknowledging the source
event. Set `WorkerOptions.rejectedCommandPolicy` only when the domain has an
explicit alternative:

- `RejectedDeadLetter` writes an idempotent row to
  `keiro.keiro_dead_letters`, acknowledges the source event, and increments the
  dispatch dead-letter metric;
- `RejectedSkip` acknowledges and counts the rejection without a durable row.

A dispatch row identifies the primitive/name, source event and global position,
emit index, target stream, error class/detail, and attempt count. Redelivery is
deduplicated by `(dispatcher_name, source_event_id, emit_index)`. Inspect one
dispatcher newest-first with `listDispatchDeadLetters`.

Choose `RejectedDeadLetter` only if advancing the source checkpoint without the
target transition preserves the aggregate's business history. It is not an
automatic retry queue.

## Subscription dead letters

Kiroku owns terminal subscription failures in `kiroku.dead_letters`. Keiro's
`Keiro.DeadLetter.Replay` module adds an operator replay path:

```haskell
rows <- listSubscriptionDeadLetters subscriptionName member
outcomes <- replaySubscriptionDeadLetters subscriptionName member handler
```

The replay helper resolves each recorded source by both event id and global
position, then invokes the caller-supplied domain handler. It returns one of:

- `ReplayedFresh` when the handler performed new writes;
- `ReplayedDuplicate` when deterministic ids proved the work was already done;
- `ReplayFailed detail` when the handler reports a decode/domain failure;
- `ReplaySourceMissing` when the source event can no longer be found.

Rows are deliberately retained and are not marked or deleted by replay. That
makes a partial run or uncertain client disconnect safe to repeat, provided the
handler is idempotent. Process-manager and router handlers satisfy this for
their writes through source-derived deterministic event ids; custom side
effects need their own idempotency key.

Never decrement or synthesize Kiroku global-position cursors. The helper scans
backward using only cursors returned by the store and matches both stored
identities before handing an event to the handler.

## Operator procedure

1. Stop or isolate the affected subscription member if live delivery could race
   the repair.
2. List the rows and identify the original failure class.
3. Fix codec, aggregate definition, infrastructure, or handler logic first.
4. Replay through a handler that reports fresh versus duplicate work.
5. Record every `ReplayOutcome`; investigate failures and missing sources.
6. Re-run the same batch if completion is uncertain, then resume the worker.

`CommandAmbiguous` is an aggregate-definition bug. Do not relabel it as a benign
duplicate: make the competing transitions mutually exclusive, deploy the fix,
and only then replay.
