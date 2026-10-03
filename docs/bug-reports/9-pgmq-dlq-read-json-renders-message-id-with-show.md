---
type: Bug Report
title: pgmq dlq read JSON renders the DLQ message id with a derived Show
description: keiro-ops --json pgmq dlq read emits dlq_message_id as the Haskell Show rendering "MessageId {unMessageId = N}" instead of a number.
generated:
  by: process:claude-code
  at: "2026-10-03T21:30:00Z"
bugId: BUG-9
status: reported
severity: degraded
origin: mori://shinzui/keiro-runtime-kenshou
affects: mori://shinzui/keiro
affectedVersion: "0.17.0.0"
environment: keiro-ops 0.17.0.0 with pgmq-core 0.6.1.0, embedded in the Kenshou binary through opsCommandTree and runOpsInvocation; PostgreSQL 18; a Keiro job queue named pick with one dead-lettered entry.
observed: 'keiro-ops --json pgmq dlq read --queue pick printed each entry with "dlq_message_id": "MessageId {unMessageId = 1}". In the same entry, original_message_id is the JSON number 1.'
expected: The documented stable JSON automation surface reports dlq_message_id as a JSON number, like original_message_id, so that a client can pass it to pgmq dlq archive --entry without knowing the Haskell type behind it.
reproduction:
  - Create a Keiro job queue and dead-letter one entry, for example by enqueueing a payload that the job codec rejects; keiro-pgmq dead-letters it as an invalid payload.
  - Run `keiro-ops --json pgmq dlq read --queue <queue>` against that database.
  - Compare dlq_message_id with original_message_id in the printed entry.
  - In mori://shinzui/keiro-runtime-kenshou, `cabal run kenshou -- run runtime/ops/correctness/keiro-ops-cross-check --out runs` does this automatically and keeps the output in diagnosis/keiro-ops-12-warehouse-pgmq-dlq-read.json; its ops-json-machine-shaped verdict records the shape.
workaround: Parse the rendering "MessageId {unMessageId = N}" and extract N. A client that does so should also accept a plain number, so it keeps working after a fix.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-03T21:35:00Z"
    document_timestamp: "2026-10-03T21:30:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: Anthropic
    model: claude-opus-5-5
    effort: low
    context: Checked dlqJson in keiro-ops/src/Keiro/Ops/Pgmq.hs at keiro-ops-0.17.0.0 and at the working tree (keiro-ops 0.19.0.0), the derived Show of MessageId in pgmq-core/src/Pgmq/Types.hs at mori://shinzui/pgmq-hs tag v0.6.1.0, the stability statement in docs/user/operations.md, and the two Kenshou runs. The suggested repair is untested.
---

# pgmq dlq read JSON renders the DLQ message id with a derived Show

`dlqJson` in `keiro-ops/src/Keiro/Ops/Pgmq.hs` renders the identifier with
`"dlq_message_id" .= showText entry.dlqMessageId`. `MessageId` in pgmq-core
(`mori://shinzui/pgmq-hs`, `pgmq-core/src/Pgmq/Types.hs`) is a record newtype
with a derived stock `Show`, so the JSON carries
`"MessageId {unMessageId = 1}"`. The same function encodes
`original_message_id` as a number, and the human table already prints the
identifier through the same `showText`. The line is unchanged at keiro-ops
0.19.0.0, so the defect is still present in the current release; only
0.17.0.0 has been run.

[docs/user/operations.md](../user/operations.md) says that `--json` "is the
stable automation surface". An operator script that reads a DLQ entry and
then archives it with `pgmq dlq archive --queue <queue> --entry <id>` must
first parse a Haskell rendering, because `--entry` accepts only a positive
integer.

Evidence: clean Kenshou runs `01a102da-b8e3-75b6-ad77-27cfd68f3acb` and
`01a102dc-cee5-7044-8331-978248c9f14f` of
`runtime/ops/correctness/keiro-ops-cross-check` recorded the rendering. Their
operator outputs are kept under `mori://shinzui/keiro-runtime-kenshou` at
`runs/<run-id>/diagnosis/`; the artifact-level Mori URI for run directories is
pending. The report source is `mori://shinzui/keiro-runtime-kenshou` at
`docs/findings/65-keiro-ops-dlq-message-id-uses-derived-show.md`; the
finding-level URI is pending.

A possible repair encodes the unwrapped integer, for example with
`"dlq_message_id" .= entry.dlqMessageId.unMessageId`, or relies on
`MessageId`'s `ToJSON` instance, which pgmq-core derives newtype-wise. This
report does not prescribe a repair.
