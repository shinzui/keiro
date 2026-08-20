---
type: Improvement Request
title: Publish WebSocket live feeds over Keiro.Wake
description: >-
  Add WebSocket live feeds for framework state — workflow status, timers, projection status —
  built on Keiro.Wake and speaking the cross-project protocol convention, with every feed
  paired to an authoritative polling read because NOTIFY is a best-effort hint, so a UI stays
  fresh without polling storms and without ever trusting push as truth.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-27
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Publish WebSocket Live Feeds over Keiro.Wake

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Companion to `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26` (the HTTP layer
these feeds live beside, in the same sister package). Implementation is keiro's downstream
work.

## Context

A UI showing running workflows, pending timers, and projection freshness must either poll
every listing aggressively — a polling storm multiplied by open browser tabs — or receive
pushes. keiro already has the push primitive: `Keiro.Wake`
(`keiro/src/Keiro/Wake.hs`) subscribes to Postgres LISTEN/NOTIFY on channel
`<schema>.events`, fired by kiroku on append, surfacing `WakeSignal` with
`WakeReason = WokenByNotify | WokenByTimeout`. The runtime itself already treats the signal
correctly: NOTIFY is best-effort — disconnected listeners miss notifications permanently,
and payloads are wake-up hints, not data — so waking falls back to timeouts, and the read
after the wake is what carries truth.

The initiative has recorded that same rule stack-wide
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`: push is a hint, poll is truth) and a
protocol convention every runtime WebSocket surface speaks
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`), a superset of the two shipped dialects in
shibuya-metrics and kiroku-metrics. keiro's feeds should be born conforming rather than
converged later.

## Requested Change

1. WebSocket feeds in the IR-26 sister package for the framework-state listings the UI renders
   live: workflow instances (status changes on the `keiro_workflows` wake ledger), timers due,
   and projection group status (the frozen `keiro_read.projection_group_status_v1` contract of
   `mori://shinzui/keiro/okf/adrs/concepts/ADR-35`). The concrete feed set is keiro's to
   finalize; workflow status is the anchor case.
2. Feeds are driven by `Keiro.Wake` (plus the timeout fallback it already models) and re-read
   state through the same supported read paths the HTTP endpoints use — never by decoding
   NOTIFY payloads as data, and never by ad-hoc SQL
   (`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`).
3. The protocol follows the cross-project convention: typed JSON frames with a `type` tag,
   explicit subscribe/unsubscribe naming what is watched, an initial `snapshot` after
   subscribe then incremental frames, `ping`/`pong` with server-side idle pings, bounded
   per-connection queues with drop-oldest overflow signaled by an in-band `error` frame, and
   `goodbye` before server-initiated close. New fields snake_case; conventions document:
   project `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`
   (artifact-level URI pending).
4. The documentation states the NOTIFY caveat verbatim: push is a best-effort hint; every feed
   pairs with a polling fallback; the feed is never the source of truth. A client that misses
   frames recovers by re-reading, not by trusting the stream was complete.

## Acceptance

1. A subscriber to the workflow feed receives a `snapshot`, then a delta frame after a
   workflow's status changes (driven end to end through a real append and wake in a test).
2. With the LISTEN connection killed mid-test, the feed degrades to timeout-driven refresh
   without client-visible corruption: the subscriber may see delayed frames but never wrong
   ones, and reconnection resumes NOTIFY-driven latency.
3. A slow consumer whose bounded queue overflows receives an in-band `error` frame signaling
   the overflow before any frame is dropped silently.
4. Every live view served by a feed is also readable through a plain HTTP endpoint returning
   the same state (the poll path exists and agrees with the feed after quiescence).
5. Protocol frames validate against the convention's structural shape; a client core written
   for the shibuya/kiroku dialect family drives these feeds with only frame-name
   configuration.

## Requested Deliverables

The feeds in the IR-26 sister package, their protocol documentation including the verbatim
NOTIFY caveat and example frames, tests for each acceptance criterion (including the killed
LISTEN connection and the overflow signal), and the paired HTTP poll endpoints where they do
not already exist under IR-26.
