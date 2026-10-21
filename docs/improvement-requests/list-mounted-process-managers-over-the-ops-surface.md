---
type: Improvement Request
title: List the mounted process managers over the ops surface
description: >-
  keiro-ops exposes `pm show` and `pm list`, both requiring `--name`, but no read that lists the
  process managers a host mounts. Add `pm types` (GET /pm/types over HTTP), mirroring
  `aggregate types`, so a UI and an operator can discover managers instead of knowing their
  names in advance.
timestamp: 2026-10-21T23:30:00Z
requestId: IR-56
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: List the Mounted Process Managers Over the Ops Surface

## Status

Proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/16-build-the-aggregates-process-managers-and-timers-screens`.
An improvement, not a dependency: the console is usable without it (see "Console behaviour
today").

## Context

`keiro-ops/src/Keiro/Ops/ProcessManager.hs` offers `show` and `list`, and both take `--name`; the
inspectors live in a catalog keyed by name (`AppHooks.processManagers`). `aggregate types`
already lists the aggregate kinds a host mounts. Nothing lists the process managers, so a client
must be told every manager name out of band.

## Console behaviour today

The console's Process managers index makes no request. It offers the names configured on the
active connection profile (Settings → Connections, "Process manager names"), the names of
managers the operator opened recently, and a field to open any manager by name. It never infers
names from stream categories. With this read, the index would list the mounted managers
directly and keep the other two sources as shortcuts.

## Requested Change

1. `keiro-ops pm types` printing the mounted managers from the catalog: name, the journal stream
   category, and whether instances carry snapshots or timers if the inspector knows.
2. Served by keiro-ops-http as `GET /pm/types` with the same `{items: [...]}` envelope as
   `/aggregate/types`, hook-gated like the other `pm` words.

## Acceptance

1. On a host mounting jitsurei's hooks, `GET /pm/types` lists the fulfillment process manager.
2. On a host without hooks it answers the same 400 `invalid_request` as `/pm/list`.
3. The JSON shape is documented beside `/aggregate/types` in
   `docs/guides/serve-keiro-ops-over-http.md`.
