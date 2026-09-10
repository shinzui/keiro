---
type: Improvement Request
title: Publish WebSocket live feeds over Keiro.Wake
description: >-
  Add WebSocket live feeds for framework state — workflow status, timers, projection status —
  built on Keiro.Wake and speaking the cross-project protocol convention, with every feed
  paired to an authoritative polling read because NOTIFY is a best-effort hint, so a UI stays
  fresh without polling storms and without ever trusting push as truth.
timestamp: 2026-09-10T02:48:00Z
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

Planned on 2026-09-10 as
[ExecPlan 277](../plans/277-publish-websocket-live-feeds-over-keiro-wake.md); the request
stays proposed until implementation and release evidence are recorded.

## Planning

[ExecPlan 277](../plans/277-publish-websocket-live-feeds-over-keiro-wake.md) (intention
`intention_01m24gb383e91rfr2dp7f2dkdz`) delivers this request inside the `keiro-ops-http`
package that [ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md) builds for
IR-26. Its design answers each requested change directly:

- The feed set is workflow instances, pending timers (scheduled or firing, in `fire_at`
  order), and projection group status, served from one WebSocket endpoint `/ws` multiplexed
  by a `feed` field in `subscribe`. Every feed is a diffed re-read of a supported library
  read: `Keiro.Workflow.Instance.listWorkflowInstances`, a new
  `Keiro.Timer.findPendingTimers` (added to the owning library first, per ADR-28, because no
  pending-timer read exists today), and `Keiro.ReadModel.Rebuild.listProjectionGroupStatuses`
  over the frozen `keiro_read.projection_group_status_v1` relation of ADR-35.
- One shared driver per distinct view (feed plus filters) waits on `Keiro.Wake` with a bounded
  fallback interval, re-reads, diffs against its previous read, and publishes one `update`
  to every subscriber, so database cost does not scale with open tabs. The `NOTIFY` payload is
  never decoded. Lease claims, crash records, suspends, lone timer schedules, and projection
  lifecycle changes never fire a notification, so the fallback interval is the worst-case
  staleness for those transitions and the documentation says so.
- The paired poll endpoints are not hand-written. keiro-ops gains two read-only commands,
  `timer pending list` and `projection status`, rendered with the same encoders the feeds
  use, and plan 276's mechanical request translation turns `wf list`, `timer pending list`,
  and `projection status` into `GET /wf/list`, `GET /timer/pending/list`, and
  `GET /projection/status`, whose bodies equal the CLI's `--json` output and the feed's
  items.
- The protocol follows the conventions: type-tagged snake_case frames (`subscribe`,
  `unsubscribe`, `ping`; `snapshot`, `update`, `unsubscribed`, `pong`, `error`, `goodbye`),
  snapshot then deltas, server-side idle pings, bounded per-connection queues with
  drop-oldest overflow signaled by an in-band `error` before any later frame, and a per-view
  `sequence` on `snapshot` and `update` so a client can detect gaps. Frames also carry
  `trigger` (`subscribe`, `notify`, `timeout`), which is what makes the killed-LISTEN
  acceptance criterion assertable rather than timed.
- Upgrades are gated by plan 276's schema-drift policy (HTTP 409 `schema_drift`), an explicit
  origin check that admits configured origins and the request's own host (HTTP 403
  `origin_not_allowed`), and a connection cap; the feeds mount onto plan 276's application
  through a separate feed handle and are served by its standalone executable by default.

Acceptance is proven by a driver-level test with `neverWake` and injected reads (overflow
ordering and fallback refresh), end-to-end WebSocket tests against a real store (a
completion append yields a notify-driven delta; feed state equals the poll route after
quiescence; a dialect-configured generic client drives the feeds), and a degradation test
that kills the `kiroku-listener` backend with `pg_terminate_backend` and observes
timeout-driven updates followed by notify-driven latency after reconnect. The plan's
Milestones 2 through 5 depend on plan 276's Milestones 1 through 3; its Milestone 1 (the
library read and the keiro-ops commands) is independent. The plan does not amend
`docs/why-keiro.md`; that remains IR-32's deliverable.

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
