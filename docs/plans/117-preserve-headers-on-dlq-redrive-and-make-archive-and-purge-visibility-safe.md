---
id: 117
slug: preserve-headers-on-dlq-redrive-and-make-archive-and-purge-visibility-safe
title: "Preserve headers on DLQ redrive and make archive and purge visibility-safe"
kind: exec-plan
created_at: 2026-07-23T03:02:27Z
master_plan: "docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md"
---

# Preserve headers on DLQ redrive and make archive and purge visibility-safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`keiro-pgmq`'s dead-letter queue (DLQ) helpers are the operator's toolbox: `readDlq` to
inspect poisoned messages, `redriveDlq` to send their payloads back to the main queue after
a fix, `archiveDlq` to retain them in PGMQ's archive table for audit, and `purgeDlq` to
delete them. The 2026-07 pgmq review (master plan:
`docs/masterplans/17-harden-keiro-pgmq-fifo-ordering-dlq-operator-paths-and-provisioning-surfaced-by-the-2026-07-pgmq-review.md`)
confirmed two operator-facing defects here. First (PGQ-3): redrive silently strips message
headers — a redriven FIFO message loses its `x-pgmq-group` key and falls into the default
group (its ordering relationship with its siblings is gone), tenant metadata in headers is
gone, and the producer's trace link is gone — even though both DLQ writers carefully
preserve the original headers inside the DLQ payload wrapper. Second (PGQ-6): the module's
own recommended inspect-then-archive-then-purge runbook destroys the audit trail if executed
within 30 seconds, because `readDlq` hides the rows it inspected behind a visibility
timeout, `archiveDlq` only sees visible rows (archiving nothing and returning 0, which
nothing checks), and `purgeDlq` truncates *everything*, hidden rows included.

After this plan, a redriven message re-enters the main queue with its original headers —
same FIFO group, same tenant metadata, same `traceparent` — pinned by a test that fails
against today's code; archiving can target the exact rows an inspection returned regardless
of visibility; `purgeDlq` refuses to destroy a queue that still has invisible (in-flight or
recently inspected) rows unless the operator explicitly forces it; and all four verbs
document the 30-second visibility window so the runbook can be followed as written without
data loss. You can see it working by running `cabal test keiro-pgmq-test` from the
repository root and reading the new DLQ examples, especially the end-to-end runbook example
that inspects, archives, and purges back-to-back with no waiting.


## Progress

- [ ] M1: `DlqEnvelope`/`parseDlqEnvelope` parse `original_headers`; `DlqEntry` exposes it; `redriveDlq` re-sends with the preserved headers when present.
- [ ] M1: Header-preservation tests pass (FIFO group key, `traceparent`, app metadata survive redrive; header-less legacy rows still redrive as before).
- [ ] M2: `purgeDlq` returns a `PurgeDlqResult` and refuses when invisible rows exist; `purgeDlqForce` provides the old unconditional behavior; `archiveDlqEntries` archives an explicit id list regardless of visibility.
- [ ] M2: Visibility-safety tests pass (purge refuses after an inspection; archive-by-ids succeeds on hidden rows).
- [ ] M3: Module haddock rewritten (visibility window on every verb, corrected runbook); end-to-end runbook example passes; full suite green.
- [ ] CHANGELOG entry for keiro-pgmq (breaking `purgeDlq` signature); ADR distillation pass done if any durable context emerged.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Redrive takes the original headers from the DLQ payload wrapper's
  `original_headers` key only; when the wrapper has none (legacy or hand-written rows), the
  message is redriven without headers exactly as today. The DLQ row's *own* row-level
  headers are deliberately not used as a fallback.
  Rationale: Both DLQ writers put the verbatim original headers in the wrapper
  (`keiro-pgmq/src/Keiro/PGMQ/Job.hs` `sendDlq`, lines 1049-1067, passes
  `mkDlqPayload message reason True`; the adapter's
  `mkDlqPayload`, `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` lines 135-160,
  writes `original_headers` when metadata is included, and keiro always includes it). The
  row-level headers of a worker-path DLQ row are *not* verbatim: the adapter merges the
  failing consumer's current trace headers over them
  (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` line 260,
  `mergeDlqHeaders consumerHdrs msg.headers`), so a row-level fallback would redrive a
  message whose `traceparent` points at the consumer's failure span instead of the
  producer's trace. Wrapper-only is the only source that is correct on both writer paths.
  Date: 2026-07-23

- Decision: Close the archive/purge visibility trap with two API changes and documentation,
  not with an upstream pgmq change: `purgeDlq` refuses (returns a typed
  `PurgeDlqBlocked` result, does not throw) when the DLQ has invisible rows, with
  `purgeDlqForce` keeping the old unconditional truncate; and a new `archiveDlqEntries`
  archives an explicit list of message ids regardless of visibility. The count-based
  `archiveDlq` keeps its semantics (visible rows only) and documents them.
  Rationale: The finding's first-preference fix — make `archiveDlq` enumerate *all* row ids
  regardless of visibility — cannot be built on the current pgmq surface: pgmq 1.11.0 has no
  SQL function that lists message ids without claiming them, and every pgmq-hasql statement
  goes through a pgmq SQL function with the queue name as a bind parameter (verified across
  `pgmq-hasql/src/Pgmq/Hasql/Statements/*.hs`; prepared statements cannot parameterize the
  table name, so a "plain SELECT msg_id" needs a new upstream SQL function and a pgmq-hs
  release). Meanwhile `pgmq.archive(queue, msg_ids[])` already ignores visibility (its
  `DELETE ... WHERE msg_id = ANY($1)` has no `vt` predicate — migration SQL lines 523-549),
  `Pgmq.batchArchiveMessages` already exposes it, and `readDlq` already returns every
  inspected row's id (`DlqEntry.dlqMessageId`) — so "archive exactly what I inspected,
  regardless of the visibility my inspection caused" is expressible today with an id-list
  API. The refusal guard is expressible today too: `pgmq.metrics` reports both total and
  visible row counts (`queueLength` vs `queueVisibleLength` on the existing
  `Pgmq.queueMetrics`). This closes the trap without adding this plan to the pgmq-hs release
  train that `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
  and `docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md` already
  coordinate. If a future need arises for count-based archiving of hidden rows, propose a
  `pgmq.list_msg_ids` upstream function then.
  Date: 2026-07-23

- Decision: `purgeDlq`'s type changes from `Eff es ()` to `Eff es PurgeDlqResult` (breaking)
  instead of keeping `()` and throwing on refusal.
  Rationale: A silent behavior change under an unchanged signature is the worst option for
  an operator verb; a changed return type makes every call site re-decide at compile time
  whether it wants the guarded verb or `purgeDlqForce`. The refusal must also be
  best-effort by construction — the metrics check and the truncate are two statements, so a
  concurrent reader between them can still hide rows that get truncated; the haddock states
  this and positions the guard as protection against the self-inflicted runbook race, not
  as a transactional fence.
  Date: 2026-07-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/keiro`) contains `keiro-pgmq`, typed
background jobs over PGMQ. PGMQ stores each queue as a PostgreSQL table `pgmq.q_<name>` and
each queue's archive as `pgmq.a_<name>`. "Reading" a message claims it by setting its `vt`
column (visibility timeout — a timestamp before which no other read returns the row) into
the future. A dead-letter queue (DLQ) is an ordinary PGMQ queue that failed messages are
moved to; for a job it is derived by `Keiro.PGMQ.Runtime.queueRef` and reachable as
`job.jobQueue.dlqName`.

All the code this plan changes is in `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` (244 lines; read it
fully before editing). The shape of a DLQ row: both writers wrap the original message in a
JSON object — the "DLQ wrapper" — with required keys `original_message` and
`dead_letter_reason` and, on every keiro path, metadata keys `original_message_id`,
`original_enqueued_at`, `last_read_at`, `read_count`, and `original_headers`. The drain-path
writer is `sendDlq` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs` (lines 1049-1067), which calls the
adapter's pure `mkDlqPayload message reason True`
(`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` lines 135-160 in the shibuya
repo at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`) — the `True`
includes the metadata, so `original_headers` is always present when the original message
had headers (the JSON value is `null` when it had none: the field is
`msg.headers :: Maybe Value`). The worker-path writer is the adapter's transactional
`deadLetterTransactionally` (`.../Pgmq/Internal.hs` lines 273-330), same wrapper.

The defects, re-verified on 2026-07-23:

PGQ-3 (confirmed; high impact for FIFO jobs). `redriveDlq` (Dlq.hs lines 154-196) parses
the wrapper with `parseDlqEnvelope` (lines 83-106), which reads `original_message`,
`dead_letter_reason`, and the three id/time/count metadata keys — but never
`original_headers`. Its `redriveOne` (lines 178-196) then re-sends *only*
`envelope.originalMessage` via `Pgmq.sendMessage` with no headers (lines 183-189; this is
the only send in the function). Consequences: a redriven FIFO message loses `x-pgmq-group`
and joins PGMQ's `_default_fifo_group`; caller metadata riding in headers is gone; the
enqueue-time `traceparent` is gone. All silent. The existing redrive test
(`keiro-pgmq/test/Main.hs` lines 718-734) enqueues a header-less payload, so it cannot
notice — a header-preservation assertion added today fails against current code.

PGQ-6 (confirmed). `readDlq` (Dlq.hs lines 108-123) reads with `delay = 30`, hiding every
inspected row for 30 seconds — intentionally, so concurrent inspections do not collide.
`archiveDlq` (lines 209-235) loops over `Pgmq.readMessage` (also `delay = 30`), so it can
only archive rows that are *visible* when it runs; when everything is hidden it reads
nothing and returns 0, and the return value is the only signal. `purgeDlq` (lines 199-201)
calls `Pgmq.deleteAllMessagesFromQueue`, which is `pgmq.purge_queue` — a `TRUNCATE TABLE`
(migration SQL lines 843-859 in
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration/migrations/0001-install-v1.11.0.sql`)
that deletes every row including invisible ones. So the module haddock's own recommended
sequence (lines 15-21: archive to retain, then purge to clear) silently archives nothing
and then permanently deletes the un-archived audit rows whenever it runs within the
30-second window after an inspection. Two facts make the fix cheap: `pgmq.archive(queue,
msg_ids[])` deletes by id with *no* `vt` predicate (SQL lines 523-549), so archiving hidden
rows by id already works — `archiveDlqEntry` (Dlq.hs lines 238-244) proves it per-row and
`Pgmq.batchArchiveMessages` exposes the batch form; and `Pgmq.queueMetrics` already reports
`queueLength` (all rows) alongside `queueVisibleLength` (visible only), so "are there
invisible rows?" is one query (`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` wraps it as
`jobDlqMetrics`).

Verified-sound context to carry (do not regress): the wrapper shape above; PGMQ's archive
is a single-statement atomic CTE (`DELETE ... RETURNING` feeding an `INSERT`, SQL lines
490-549), so a crash cannot leave a row in both the queue and the archive; redrive is
documented at-least-once (send to main queue, then delete from DLQ — a crash between the
two duplicates the message; module haddock lines 23-25); and the existing DLQ examples in
`keiro-pgmq/test/Main.hs` — readDlq decode (line 701), redrive round-trip (line 718), purge
(line 736), malformed wrapper (line 746), archive retention (line 1223), archive survives
purge (line 1239) — all stay green unmodified.

Relevant ADR: `docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` (the only ADR
in `docs/adr/`) fixes the one-process-span-per-delivery telemetry contract on the worker and
one-shot execution paths. This plan does not touch those paths — `Dlq.hs` has no spans and
gets none (its PGMQ operations are traced by the `pgmq-effectful` interpreter like any
other) — but its tests drive `runJobOnce` to *produce* DLQ rows, and those drives must keep
using the public API so the contract's captured-span examples remain representative. State
changes here must not alter `sendDlq` or the drain fold; if an edit seems to need that, it
belongs to `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
instead.

Sibling plans: FIFO delivery enforcement is
`docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
(note: it adds a required `jobOrdering` field to `Job`; if it lands before this plan, the
new tests here construct jobs with that field — follow the compiler). Provisioning and
retention documentation is
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`; it also
corrects a *different* sentence of the Dlq module haddock (the "PGMQ does not expire DLQ
rows by itself" claim, false for partitioned queues). Coordinate the haddock edits by
keeping each plan's sentence-level change scoped to its own finding.


## Plan of Work

### Milestone 1 — redrive preserves the original headers (PGQ-3)

Scope: parse `original_headers` out of the DLQ wrapper, expose it to operators on
`DlqEntry`, and re-send it on redrive. At the end, a dead-lettered FIFO message redriven to
the main queue is read back with its `x-pgmq-group`, `traceparent`, and application header
keys intact — asserted by tests that fail against today's code.

All edits in `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`:

1. Extend the internal `DlqEnvelope` (lines 75-81) with
   `envelopeOriginalHeaders :: !(Maybe Value)` and parse it in `parseDlqEnvelope`'s parser
   (lines 87-102) with `obj .:? "original_headers"`, then normalize JSON `null` to
   `Nothing` (the drain-path writer serializes `Maybe Value`, so a header-less original
   yields `"original_headers": null`; treat `Just Null` as `Nothing` so the redrive branch
   below stays honest). Aeson note for the implementer: `.:?` on a present-but-null field
   yields `Just Null` for a `Maybe Value` target only via `parseJSON`; write the
   normalization explicitly rather than relying on instance subtleties:

   ```haskell
   rawHeaders <- obj .:? "original_headers"
   let envelopeOriginalHeaders = case rawHeaders of
           Just Null -> Nothing
           other -> other
   ```

2. Expose it on the public record: add `originalHeaders :: !(Maybe Value)` to `DlqEntry`
   (lines 60-73) with a haddock ("the preserved PGMQ headers of the original message —
   group key, trace context, caller metadata — when the DLQ writer recorded them"), fill it
   in `toEntry` (lines 125-148: `Nothing` in the malformed branch, the parsed value in the
   happy branch). This is additive but changes the record's field set; the record is
   constructed only inside this module, so no external breakage.

3. In `redriveOne` (lines 178-196), branch on the parsed headers; import
   `SendMessageWithHeaders (..)` and `MessageHeaders (..)` from `Pgmq.Effectful` (extend
   the existing import list at lines 45-53):

   ```haskell
   Right envelope -> do
       _ <- case envelope.envelopeOriginalHeaders of
           Just headers ->
               Pgmq.sendMessageWithHeaders
                   SendMessageWithHeaders
                       { queueName = job.jobQueue.physicalName
                       , messageBody = MessageBody envelope.originalMessage
                       , messageHeaders = MessageHeaders headers
                       , delay = Nothing
                       }
           Nothing ->
               Pgmq.sendMessage
                   SendMessage
                       { queueName = job.jobQueue.physicalName
                       , messageBody = MessageBody envelope.originalMessage
                       , delay = Nothing
                       }
       ...delete unchanged...
   ```

4. Update `redriveDlq`'s haddock (lines 150-153): redriven messages carry the original
   headers when the DLQ wrapper preserved them (all keiro-written rows), so a FIFO
   message returns to its group and the trace link survives; wrappers without
   `original_headers` redrive header-less.

New tests in `keiro-pgmq/test/Main.hs`, next to the existing redrive example (line 718).
Use the existing helpers: `enqueueWithHeaders`/`enqueueToGroup` to produce a message with
headers, a `Dead`-returning handler via `runJobOnce` to dead-letter it, `redriveDlq`, then
`readMessages job.jobQueue.physicalName 1` and the suite's `headerKey` helper to inspect
the redriven row's raw headers:

- "redriveDlq preserves the FIFO group key": enqueue with `enqueueToGroup job "g1" p`,
  dead-letter, redrive, read the main-queue row raw, assert
  `headerKey "x-pgmq-group" m.headers == Just (String "g1")`.
- "redriveDlq preserves trace and application headers": enqueue with
  `enqueueWithHeaders job (MessageHeaders (object ["traceparent" .= t, "x-tenant" .= String "acme"])) p`
  where `t` is a fixed valid W3C value (copy the literal from the existing traceparent
  example at line 862), dead-letter, redrive, assert both keys survive verbatim.
- "redriveDlq without preserved headers behaves as before": send a hand-written wrapper
  containing only `original_message` and `dead_letter_reason` directly to the DLQ with
  `Pgmq.sendMessage` (the malformed-wrapper example at line 746 shows the technique),
  redrive, assert the main-queue row has no headers and the redrive count is 1.
- Extend the readDlq decode example (line 701) or add a sibling: `originalHeaders` on the
  entry is `Just` the enqueued header object for a headered original and `Nothing` for a
  header-less one.

Acceptance: the two preservation examples fail before the `Dlq.hs` edit (run them against
stashed changes to confirm at least once) and pass after; the whole suite is green.

### Milestone 2 — archive by explicit ids; purge refuses over invisible rows (PGQ-6)

Scope: give the runbook a visibility-proof archive step and a guarded purge. At the end an
operator can inspect and immediately archive exactly what was inspected, and cannot
truncate hidden rows without typing "force".

All edits in `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` (plus its import list and the export list
at lines 27-34):

1. Add `archiveDlqEntries`:

   ```haskell
   -- | Archive (retain) exactly these DLQ rows by id, regardless of their
   -- visibility state. PGMQ's @archive@ has no visibility predicate, so rows
   -- hidden by a prior 'readDlq' inspection are archived too — this is the
   -- verb to pair with 'readDlq': archive the 'dlqMessageId's you inspected.
   -- Returns the ids actually moved (already-archived or unknown ids are
   -- reported missing by omission). Empty input issues no statement.
   archiveDlqEntries :: (Pgmq :> es, IOE :> es) => Job p -> [MessageId] -> Eff es [MessageId]
   archiveDlqEntries _ [] = pure []
   archiveDlqEntries job msgIds =
       Pgmq.batchArchiveMessages
           BatchMessageQuery
               { queueName = job.jobQueue.dlqName
               , messageIds = msgIds
               }
   ```

   Import `BatchMessageQuery (..)` from `Pgmq.Effectful`. (Check the record's exact field
   names in `pgmq-hasql`'s `Pgmq.Hasql.Statements.Types` before writing; `pgmq-effectful`
   re-exports it and the operation `batchArchiveMessages :: BatchMessageQuery -> Eff es [MessageId]`
   exists at `pgmq-effectful/src/Pgmq/Effectful/Effect.hs` lines 269-270.)

2. Replace `purgeDlq` (lines 198-201) with a guarded version plus a force escape hatch:

   ```haskell
   -- | The outcome of a guarded 'purgeDlq'.
   data PurgeDlqResult
       = -- | The DLQ was truncated; this many rows were deleted.
         PurgeDlqPurged !Int64
       | -- | Refused: this many rows are currently invisible (claimed by an
         -- inspection, a redrive in progress, or an in-flight consumer).
         -- Deleting them would destroy rows an operator may believe are safe
         -- in the archive. Wait out the visibility window, archive by id
         -- ('archiveDlqEntries'), or use 'purgeDlqForce'.
         PurgeDlqBlocked !Int64
       deriving stock (Eq, Show)

   -- | Delete all rows in the DLQ — unless some are invisible, in which case
   -- refuse with 'PurgeDlqBlocked'. The check and the truncate are separate
   -- statements: a reader that claims a row between them is not detected, so
   -- this guards the documented runbook race, not concurrent operators.
   purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es PurgeDlqResult
   purgeDlq job = do
       metrics <- Pgmq.queueMetrics job.jobQueue.dlqName
       let invisible = metrics.queueLength - metrics.queueVisibleLength
       if invisible > 0
           then pure (PurgeDlqBlocked invisible)
           else PurgeDlqPurged <$> Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName

   -- | Unconditionally delete all rows in the DLQ, invisible ones included
   -- (PGMQ @purge_queue@, a TRUNCATE). The pre-plan behavior of 'purgeDlq'.
   purgeDlqForce :: (Pgmq :> es, IOE :> es) => Job p -> Eff es Int64
   purgeDlqForce job = Pgmq.deleteAllMessagesFromQueue job.jobQueue.dlqName
   ```

   `QueueMetrics`'s field names are `queueLength` and `queueVisibleLength`
   (`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs` uses both). Export `PurgeDlqResult (..)`,
   `purgeDlqForce`, and `archiveDlqEntries`; keep exporting `purgeDlq`.

3. Document the visibility window on the count-based `archiveDlq` (lines 203-208): it
   archives *visible* rows only — rows hidden by a prior inspection are skipped and do not
   count; use `archiveDlqEntries` with the inspected ids to archive through the window.
   Do not change its behavior.

4. Update the one existing `purgeDlq` call site in tests: the "purgeDlq empties the DLQ"
   example (`test/Main.hs` line 736) and "archived DLQ rows survive a purge" (line 1239)
   now bind the result (assert `PurgeDlqPurged 1` in the former; in the latter the archive
   ran first so `PurgeDlqPurged 0` — adjust to what the archive left, currently zero rows).

New tests in `keiro-pgmq/test/Main.hs`:

- "purgeDlq refuses while inspected rows are hidden": dead-letter one message, `readDlq
  job 1` (hides it for 30 s), then `purgeDlq` — assert `PurgeDlqBlocked 1` and DLQ
  `queueLength` still 1.
- "purgeDlqForce truncates hidden rows": same setup, `purgeDlqForce` returns 1, DLQ empty.
  (This pins the sharp edge deliberately: the force verb exists and is destructive.)
- "archiveDlqEntries archives rows a prior inspection hid": dead-letter two messages,
  `entries <- readDlq job 2`, immediately
  `archiveDlqEntries job (fmap (.dlqMessageId) entries)` — assert both ids returned, DLQ
  `queueLength` 0, and `archiveCount` (existing raw-SQL helper, `test/Main.hs` lines
  106-120) reports 2.
- "count-based archiveDlq skips hidden rows (documented)": dead-letter one, `readDlq job 1`,
  then `archiveDlq job 10` — assert it returns 0 and the row still exists. This pins the
  documented limitation so a future change to it is deliberate.

Acceptance: suite green; the refusal example fails against pre-plan code (old `purgeDlq`
returned `()` and deleted the hidden row).

### Milestone 3 — a truthful runbook, end to end

Scope: rewrite the module haddock's operational guidance and prove the corrected runbook
with one end-to-end example. At the end, an operator following the haddock verbatim cannot
lose audit rows to the visibility window.

1. Rewrite the `Keiro.PGMQ.Dlq` module haddock (lines 6-26). Keep the wrapper-shape
   paragraph and the at-least-once redrive paragraph. Replace the retention paragraph with
   the corrected runbook, in prose along these lines: every read-based verb (`readDlq`,
   `redriveDlq`, `archiveDlq`) claims the rows it touches for 30 seconds; within that
   window those rows are invisible to the other verbs. The audit-safe sequence is:
   `readDlq` to inspect, `archiveDlqEntries` with the inspected `dlqMessageId`s to retain
   exactly those rows (archive-by-id sees through the window), then `purgeDlq` — which
   refuses with `PurgeDlqBlocked` if anything is still invisible (someone else inspecting,
   a redrive mid-flight) and `purgeDlqForce` for the eyes-open override. Mention that a
   redriven message keeps its original headers (M1). Do not touch the "PGMQ does not expire
   DLQ rows by itself" sentence — its correction (it is false for partitioned queues)
   belongs to `docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`.

2. Add the end-to-end example "the documented inspect-archive-purge runbook is
   visibility-safe": dead-letter two messages; with no sleeps anywhere run
   `entries <- readDlq job 10`, `archiveDlqEntries job (fmap (.dlqMessageId) entries)`,
   `purgeDlq job`; assert two entries were read, two ids archived, the purge result is
   `PurgeDlqPurged 0` (nothing left un-archived), `archiveCount` reports 2, and the DLQ is
   empty. Against pre-plan code this exact sequence archived zero and truncated both rows —
   the example is the finding, inverted.

Acceptance: `cabal test keiro-pgmq-test` fully green; reading the module haddock top to
bottom describes exactly what the code now does.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/keiro`. The suite
starts its own PostgreSQL (keiro-test-support template-database fixture); no external
database or environment variables are needed.

Baseline before any edit:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-pgmq-test
```

Expected tail:

```text
58 examples, 0 failures, 2 pending
Test suite keiro-pgmq-test: PASS
```

(The two pending examples are pre-existing and unrelated: `test/Main.hs` lines 645 and
1096.) If `docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md`
has landed first, the baseline count is higher and `Job` records need its `jobOrdering`
field — the compiler will say so; this plan's FIFO redrive tests then declare
`jobOrdering = FifoThroughput`.

Then per milestone: edit as described, re-run the same command, and commit on green with
Conventional Commits:

```text
fix(keiro-pgmq): preserve original headers on DLQ redrive
feat(keiro-pgmq)!: guard purgeDlq behind a visibility check and add archiveDlqEntries
docs(keiro-pgmq): correct the DLQ runbook for the visibility window
```

To demonstrate that the M1 preservation tests bite, run them once against the unedited
`Dlq.hs` (for example, write the tests first and observe the failures):

```text
expected: Just (String "g1")
 but got: Nothing
```


## Validation and Acceptance

The plan is done when all of the following are observable from the repository root:

1. `cabal test keiro-pgmq-test` prints `0 failures, 2 pending`, with the example count
   grown by this plan's nine new examples (record the exact final count in Progress).
2. A dead-lettered message enqueued with `enqueueToGroup job "g1" p`, after `redriveDlq`,
   is read back from the main queue with `x-pgmq-group = "g1"` — and the analogous
   assertions hold for `traceparent` and an application header key.
3. The sequence `readDlq` → `purgeDlq` with no wait refuses: the purge returns
   `PurgeDlqBlocked n` with `n > 0` and deletes nothing.
4. The sequence `readDlq` → `archiveDlqEntries (inspected ids)` → `purgeDlq` with no wait
   retains every inspected row in `pgmq.a_<dlq>` (raw-SQL `archiveCount` proves it) and
   ends with an empty DLQ.
5. All six pre-existing DLQ examples pass unmodified except the two `purgeDlq` call sites,
   which changed only because the return type did (their assertions are strictly
   stronger, never weaker).
6. The ADR-0001 captured-span examples (`test/Main.hs` lines 901-1060) pass unmodified —
   this plan never touches the drain or worker execution paths.


## Idempotence and Recovery

Every edit is an ordinary source change under test; re-running any step is safe, and the
test fixture clones a fresh database per example so failed runs leave no residue.

The `purgeDlq` signature change is compile-loud: any call site not updated fails to build.
If a consumer outside this repository needs the old behavior verbatim, `purgeDlqForce` *is*
the old behavior (modulo also returning the deleted count).

Operationally nothing in this plan is destructive beyond what the verbs already were:
`archiveDlqEntries` only moves rows into the archive (atomic single statement upstream);
the newly guarded `purgeDlq` strictly refuses in more cases than before; only
`purgeDlqForce` retains the old truncate-everything semantics, clearly named. If M2 must be
rolled back independently, M1 stands alone (redrive headers have no dependency on the
archive/purge changes), and vice versa.


## Interfaces and Dependencies

At the end of the plan, `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs` exports (module
`Keiro.PGMQ.Dlq`, re-exported through `Keiro.PGMQ`):

```haskell
data DlqEntry p = DlqEntry
    { dlqMessageId :: !MessageId
    , reason :: !Text
    , originalPayload :: !(Either JobDecodeError p)
    , originalMessageId :: !(Maybe Int64)
    , originalEnqueuedAt :: !(Maybe UTCTime)
    , readCount :: !(Maybe Int64)
    , originalHeaders :: !(Maybe Value)  -- new
    , rawBody :: !Value
    }

readDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int32 -> Eff es [DlqEntry p]      -- unchanged
redriveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int              -- unchanged type, preserves headers
archiveDlq :: (Pgmq :> es, IOE :> es) => Job p -> Int -> Eff es Int              -- unchanged, documented
archiveDlqEntry :: (Pgmq :> es, IOE :> es) => Job p -> MessageId -> Eff es Bool  -- unchanged
archiveDlqEntries :: (Pgmq :> es, IOE :> es) => Job p -> [MessageId] -> Eff es [MessageId]  -- new

data PurgeDlqResult = PurgeDlqPurged !Int64 | PurgeDlqBlocked !Int64             -- new
purgeDlq :: (Pgmq :> es, IOE :> es) => Job p -> Eff es PurgeDlqResult            -- breaking: was Eff es ()
purgeDlqForce :: (Pgmq :> es, IOE :> es) => Job p -> Eff es Int64                -- new: old behavior
```

Dependencies, all already in `keiro-pgmq.cabal` with satisfied bounds (`pgmq-effectful
>=0.4 && <0.5`): `Pgmq.Effectful`'s existing operations `sendMessageWithHeaders`,
`batchArchiveMessages` (with `BatchMessageQuery`), `queueMetrics` (with `QueueMetrics`'s
`queueLength`/`queueVisibleLength`), and `deleteAllMessagesFromQueue`. No pgmq-hs, shibuya,
or SQL-migration change is required by this plan (see the Decision Log for why), so it
rides no release train and can land in any order relative to its siblings
`docs/plans/116-enforce-fifo-group-ordering-under-failure-and-batched-consumption.md` and
`docs/plans/118-correct-partitioned-retention-semantics-and-the-fifo-index.md`.
