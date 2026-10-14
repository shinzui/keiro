---
type: Improvement Request
title: Reject shard count mismatch without changing shard rows
description: >-
  Validate a sharded subscription's configured bucket count before inserting
  rows, so a misconfigured worker cannot prevent correct workers from starting.
timestamp: 2026-10-14T13:54:48Z
requestId: IR-49
status: in-progress
origin: mori://shinzui/keiro-runtime-kenshou
plan: mori://shinzui/kiroku/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption
reviews:
  - kind: model
    reviewer: codex-cli
    reviewed_at: 2026-09-24T13:34:00Z
    document_timestamp: 2026-09-24T13:34:00Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6-sol
    effort: medium
    context: >-
      Confirmed the failing external scenario on released Keiro 0.17.0.0 and
      inspected ensureShards and its post-commit mismatch check at 64063b10.
---

# Improvement Request: Reject Shard Count Mismatch Without Changing Shard Rows

## Status

Implemented in Keiro commit `2c3a5389353d290b532cafff14122bf9ab1af79a`
as downstream work under
`mori://shinzui/kiroku/plans/85-release-the-subscription-hardening-cohort-and-coordinate-downstream-adoption`,
and included in the published Keiro 0.20.0.0 tag. `ensureShards` now acquires the
subscription-name transaction lock, checks existing counts, and inserts only
when they agree. The regression in `keiro/test/Main.hs` verifies a count-six
refusal leaves the four original rows intact; the retained
[shard test report](../../keiro/bench/results/mp12-kiroku-adoption/focused-shards.log)
passes all 22 examples.

The request remains in progress: the full two/six/four worker-start sequence,
competing-count concurrent startup, and a passing rerun of the originating
external scenario are not recorded in the retained acceptance evidence.
The historical failure below describes the original 0.17.0.0 reproduction.

## Observed behavior

On the released Keiro 0.17.0.0 cohort, a subscription initialized with four
shards accepts four rows. `ensureShards` called with a count of two throws
`ShardCountMismatch` without changing the row count. Calling it with a count
of six also throws, but leaves six rows. A subsequent correctly configured
four-shard caller then throws `ShardCountMismatch`. The verification scenario
`keiro/shard/correctness/shard-count-mismatch` reports violations of
`shard-larger-worker-left-four` and `shard-correct-worker-recovers`.

The source at Keiro commit `64063b10` confirms the sequence in
`keiro/src/Keiro/Subscription/Shard.hs`: `ensureShards` commits
`ensureShardRows` and `listShardCounts` in `runTransaction`, then checks
the returned counts and throws. Inserting buckets four and five therefore
survives the exception. The source path is repository local; the originating
verification plan is
`mori://shinzui/keiro-runtime-kenshou/plans/14-cover-keiro-durable-execution-timers-and-sharded-subscriptions`.

## Requested behavior

A worker with a different configured shard count must be rejected before it
changes the durable rows for that subscription. Starting a correctly
configured worker afterwards must still succeed without manual repair.
Concurrent startup by workers with different counts must settle on one count
without leaving a mixed table. Keep the existing `ShardCountMismatch` result
and include the observed count for diagnosis.

## Acceptance

Initialize a four-shard subscription, attempt starts with counts two and six,
then start another four-shard worker. Both mismatched starts report
`ShardCountMismatch`, the table still has exactly buckets zero through three,
and the final worker starts and acquires a bucket. Repeat the same test with
concurrent startup to cover the check-and-insert race. The originating
scenario in `mori://shinzui/keiro-runtime-kenshou` (repository-relative path
`kenshou-keiro/src/Kenshou/Suite/Keiro/Shard/Mismatch.hs`; artifact-level URI
pending) supplies an external regression probe.
