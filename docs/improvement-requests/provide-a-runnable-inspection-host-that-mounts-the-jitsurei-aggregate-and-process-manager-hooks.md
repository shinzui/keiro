---
type: Improvement Request
title: Provide a runnable inspection host that mounts the jitsurei aggregate and process-manager hooks
description: >-
  Every process an operator can start today serves keiro-ops-http with emptyAppHooks, so
  /aggregate/* and /pm/* do not exist anywhere outside the test suite even though jitsurei
  defines the inspectors. Ship an executable, or a flag on the compose example, that mounts
  jitsurei's AppHooks against the jitsurei database so UIs can be built and verified against
  real aggregate and process-manager responses.
timestamp: 2026-10-21T21:00:00Z
requestId: IR-55
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Provide a Runnable Inspection Host That Mounts the Jitsurei Aggregate and Process-Manager Hooks

## Status

Proposed by the keiro runtime console initiative
(`mori://shinzui/keiro-ui/masterplans/2-build-the-keiro-runtime-console`), filed from
`mori://shinzui/keiro-ui/plans/9-provision-the-local-runtime-stack-and-recorded-fixtures`.
Not a dependency of any plan there: the console is built and tested against fixtures
hand-derived from keiro's encoders until a host exists, then re-recorded.

## Context

`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-28` and IR-29 added aggregate and
process-manager inspection to the keiro-ops command tree, and keiro-ops-http serves those
command words when the host passes `AppHooks` with `aggregates` and `processManagers`.
`jitsurei/src/Jitsurei/Inspection.hs` already defines the inspectors for the example's
aggregates and its fulfillment process manager.

Neither runnable host mounts them: `keiro-ops-http/app/Main.hs` and
`keiro-ops-http/example/Compose.hs` both use `emptyAppHooks`. The routes are therefore
reachable only inside `keiro-ops-http/test/Main.hs` (`seedInspection`). A UI built against
keiro (the keiro runtime console, with its aggregate browser and process-manager timeline)
cannot record a real `/aggregate/show` or `/pm/show` response, so its fixtures are derived
by hand from `Keiro.Inspection.Aggregate` and `Keiro.ProcessManager.Inspect`, and drift in
those encoders goes unnoticed until someone mounts the hooks.

## Requested Change

1. An executable (for example `jitsurei-ops-http`), or a flag on
   `keiro-ops-http-compose-example`, that constructs `AppHooks` from
   `jitsurei/src/Jitsurei/Inspection.hs` and serves the full keiro-ops HTTP surface,
   including `/aggregate/types|list|show|snapshot` and `/pm/list|show`, against the
   database `just jitsurei-all` seeds.
2. The same flags as `keiro-ops-http` (`--database-url`, `--port`, repeatable
   `--allow-origin`, `--enable-mutations`), so it can replace the standalone server in a local
   stack without other changes.
3. A Justfile recipe that starts it against the jitsurei database.

## Acceptance

1. After `just jitsurei-all`, the new host answers `GET /aggregate/types` with jitsurei's
   aggregate kinds and `GET /aggregate/show?name=order&id=<id>` with a hydrated order for an
   aggregate the demo wrote.
2. `GET /pm/list?name=<manager>` and `GET /pm/show?name=<manager>&correlation=<id>` answer
   for the fulfillment process manager the demo drives.
3. Every route `keiro-ops-http` serves is served identically (same schema check, origin rules,
   and mutation gate).

## Requested Deliverables

The executable or flag, the recipe, and a short section in
`docs/guides/serve-keiro-ops-over-http.md` naming it as the way to see the hook-gated routes
locally.
