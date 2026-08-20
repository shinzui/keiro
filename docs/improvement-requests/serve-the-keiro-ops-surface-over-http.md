---
type: Improvement Request
title: Serve the keiro-ops surface over HTTP
description: >-
  Add a sister package that serves the read-only subset of the typed keiro-ops command tree as
  JSON endpoints reusing the OpsResult envelope, with mutations exposed only behind the existing
  preview/force discipline and the fail-closed schema-drift handshake, so a browser UI can reach
  the operational surface applications already embed as a CLI.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-26
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Serve the keiro-ops Surface over HTTP

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`). The
initiative is preparing a browser UI for applications built on the keiro runtime; per its
recorded ownership principle (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`),
framework-level operational views belong to keiro. This request engages keiro's recorded
no-UI stance through its companion
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-32`, which proposes recording the
boundary in an ADR. Implementation is keiro's downstream work.

## Context

keiro has no HTTP server, no WebSocket endpoint, and no network listener of any kind — a
stated stance (`docs/why-keiro.md`: observability flows through OpenTelemetry into the
operator's own dashboards), not an oversight. Yet the operational surface a UI needs already
exists, fully typed, as `keiro-ops`: an embeddable CLI whose `Keiro.Ops` module exports
`mainWithHooks`, `AppHooks`, `opsCommandTree`, and `runOpsInvocation`, whose every command
renders into the stable machine envelope `OpsResult { headers, rows, jsonValue }`
(`Keiro.Ops.Render`), whose `isMutation :: Command -> Bool` classifies every command as read
or write, whose mutations return `PreviewRequired` and refuse to act without `--force`, and
whose every invocation fails closed on schema drift unless `--allow-schema-drift` is passed.
Command domains cover workflows, timers, streams, outbox/inbox, pgmq DLQs, projections,
shards, snapshots, rebuilds, and replay audits.

What is missing is only the transport: a browser cannot invoke a CLI. OpenTelemetry dashboards
cannot fill the gap either — they show metrics and traces, not state browsing or safe operator
actions.

The constraining decision is `mori://shinzui/keiro/okf/adrs/concepts/ADR-28`: operator
commands wrap supported library APIs, never ad-hoc SQL; and keiro surfaces report positions in
its fixed vocabulary (`store_position`, `visible_store_head`, "global position distance" —
never "lag" or "backlog"). An HTTP layer over `keiro-ops` inherits both rules by construction,
because it reuses the same command implementations.

## Requested Change

1. A sister package (working name `keiro-ops-http`; `keiro-http` is equally acceptable) that
   exposes an embeddable WAI `Application` — the pattern kiroku's `kiroku-metrics` and
   shibuya's `shibuya-metrics` already follow in their repositories, recorded stack-wide as
   `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`. No web dependency enters any existing
   keiro package. Applications embed the application via the same `AppHooks` they already
   mount for the CLI, and the package also offers a convenience runner with host-chosen bind
   address and port.
2. The read-only subset of `opsCommandTree` — derived mechanically from `isMutation`, never
   from a hand-maintained list — served as JSON endpoints whose response bodies are the same
   `jsonValue` the CLI's `--json` emits for the equivalent invocation.
3. Mutations exposed only behind the existing discipline, translated to HTTP: a first call
   returns the preview (the `PreviewRequired` rendering) and performs nothing; only an
   explicit confirmed call — carrying an unmistakable confirmation parameter — executes. The
   schema-drift handshake stays fail-closed: on drift, endpoints refuse with a structured
   error rather than emitting partial output. Whether mutations are mounted at all is a host
   configuration choice, disabled by default.
4. Wire conventions per the initiative's conventions document (project
   `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`,
   artifact-level URI pending): snake_case new fields, cursor pagination where listings page,
   the structured error envelope, and configurable CORS (explicit allowed-origins list,
   disabled by default).

## Acceptance

1. For every read-only command in `opsCommandTree`, the corresponding endpoint returns the
   same `jsonValue` that `keiro-ops <command> --json` emits against the same database state —
   demonstrated by a test that diffs the two for a representative command in each domain.
2. Invoking a mutation endpoint without confirmation returns the preview and changes nothing
   (asserted against the database); the confirmed call performs exactly what the CLI's
   `--force` path performs.
3. With schema drift induced in a test, every endpoint refuses with a structured error; none
   emits partial data.
4. With mutations disabled in configuration (the default), mutation routes refuse even with
   confirmation.
5. No existing keiro package gains a web dependency (checked by inspecting the build plans);
   the new package exports the bare WAI `Application`.
6. Responses use keiro's reporting vocabulary per ADR-28 — a grep of response fixtures finds
   `store_position`/`visible_store_head` and never `lag` or `backlog`.

## Requested Deliverables

The sister package with the mechanical read/write split, preview/confirm mutation flow,
schema-drift refusal, CORS configuration, tests for each acceptance criterion, and user
documentation with copyable request/response transcripts. The stance ADR itself is requested
separately (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-32`).
