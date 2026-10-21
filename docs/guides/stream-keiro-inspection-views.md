---
type: Runbook
title: Stream Keiro Inspection Views
description: Mount bounded workflow, timer and projection-group feeds and recover clients through their paired poll reads.
timestamp: 2026-10-21T03:07:07Z
docId: DOC-31
tags: [keiro, operations, http, inspection, websocket]
generated:
  by: openai/codex
  at: 2026-10-21T03:08:38Z
---

# Stream Keiro Inspection Views

The standalone `keiro-ops-http` server mounts `/ws` alongside its existing
read-only command routes. Keep it on the trusted network or behind the same
authenticating proxy used for HTTP inspection. Mutations remain off by default
and are never accepted as socket frames.

For an embedded host, construct the handle and application once, using the
inspection store with its own reserved pool capacity and SQL deadline:

```haskell
withFeedHandle httpConfig defaultFeedConfig inspectionStore $ \feeds -> do
  app <- opsApplicationWithFeeds httpConfig feeds hooks inspectionStore
  withOpsHttpServer serverConfig app $ \server -> wait server.serverThread
```

Close the server before releasing the feed handle and store. The application
and handle must use the same host policy. A composed host applies HTTP CORS
once: construct its HTTP child with an empty HTTP origin list via
`opsApplicationWithBudget`, then wrap it with `feedsMiddleware` using the full
socket origin policy and the handle's shared budget. Mounting at `/keiro`
rewrites both WAI path fields, making the socket `/keiro/ws`; frames contain no
absolute URLs.

## Subscribe and recover

Send JSON text frames. Workflows accept `status_class`, `workflow_name` and
`limit`; timers accept `manager`, `correlation_id` and `limit`; projection groups
accept `limit`. Unknown fields and invalid limits are refused. Limits are
1 through the host maximum, at most 500, with a default of 100.

```json
{"type":"subscribe","feed":"workflows","status_class":["running","sleeping"],"limit":100}
{"type":"subscribe","feed":"timers","manager":"escalation","limit":100}
{"type":"subscribe","feed":"projection_groups"}
```

Each connection has at most one subscription per feed. A successful replacement
sends a new snapshot; a refused replacement keeps the old view. Equivalent
filters share a driver across connections. Feeds watch the first page only.
Use `/wf/inspect/list`, `/timer/pending/list` and `/projection/status` to poll or
page the corresponding state. The timer poll option is `correlation`; the
socket field and returned item field are `correlation_id`.

```json
{"type":"snapshot","feed":"workflows","sequence":0,"trigger":"subscribe","observed_at":"2026-10-21T03:00:00Z","items":[]}
{"type":"update","feed":"workflows","sequence":1,"trigger":"notify","observed_at":"2026-10-21T03:00:01Z","changed":[],"removed":[{"workflow_name":"approval","workflow_id":"one"}]}
{"type":"error","code":"queue_overflow","message":"frames were dropped for this feed; re-subscribe or re-read","feed":"workflows"}
```

Replace local state on `snapshot`. On `update`, replace `changed` items by key
and remove the supplied key objects. Removed items left this first-page view;
that alone does not prove they were deleted or completed. Keys are workflow
name/id, timer id, or projection group id. Sequence increases per published
update of the shared view. A gap or `queue_overflow` means local state needs a
fresh snapshot or poll; surviving deltas alone cannot repair it. Control frames
share the queue budget, so overflow reporting may evict another old delta.

`read_failed` retains the last known view while the driver retries. Initial read
failure sends an error, never an invented empty snapshot. Projection frames also
carry `visible_store_head`; an update may have empty `changed` and `removed`
when only that observation changes. Position differences are global position
distance, not event lag or backlog.

```json
{"type":"ping"}
{"type":"pong"}
{"type":"unsubscribe","feed":"workflows"}
{"type":"unsubscribed","feed":"workflows"}
{"type":"goodbye"}
```

The server sends WebSocket keep-alive pings while idle and a `goodbye` on active
handle shutdown. Reconnect and re-subscribe after close. Unknown frame types,
unknown feeds and invalid subscriptions receive typed in-band errors. Upgrade
requests enforce the origin allowlist (same-origin is accepted), schema policy
and connection cap before acceptance. The request-byte cap also bounds incoming
socket messages.

## Cost and freshness

Default limits are 32 distinct views, 256 connections, 500 items, a 1 MiB frame,
2 MiB queued bytes and 256 frames per connection. Controls must fit within the
byte limits (at least 256 bytes). Reads and encoding have a five-second deadline
and share the HTTP admission budget; sends also have a deadline. An
`inspection_result_too_large` error requires a smaller view or different host
limits. A row limit does not bound the size of an individual payload.

Workflow and projection refreshes default to a minimum one-second interval.
Timer refreshes are at least five seconds apart and currently support the
measured envelope of at most 100,000 timer ledger rows; larger ledgers require
new evidence before automatic refresh. Timer `due_in_seconds` is relative to
that frame's database `observed_at`; derive a live countdown from `fire_at` on
the client. Clock passage alone does not create timer updates.

NOTIFY is best-effort: notifications can be dropped while a listener is
disconnected. Push is a hint and poll is truth. Drivers always use a fallback
read and never decode notification payloads. Some writes, including standalone
timer schedules, leases and projection lifecycle changes, produce no append
notification. The fallback is a scheduling interval, not a guaranteed maximum
staleness under slow queries or saturation. An idle handle with no views runs
no refreshes and holds no duplicated notification cursor.
