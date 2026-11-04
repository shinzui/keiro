---
type: Improvement Request
title: Serve the keiro-ops surface over HTTP
description: >-
  Add a sister package that serves the read-only subset of the typed keiro-ops command tree as
  JSON endpoints reusing the OpsResult envelope, with mutations exposed only behind the existing
  preview/force discipline and the fail-closed schema-drift handshake, so a browser UI can reach
  the operational surface applications already embed as a CLI.
timestamp: 2026-11-04T05:28:05Z
requestId: IR-26
status: completed
origin: mori://shinzui/keiro-ui
plan: docs/plans/276-serve-the-keiro-ops-surface-over-http.md
relatedPlans:
  - docs/plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md
  - docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
  - docs/plans/326-make-releases-preflighted-resumable-and-isolated.md
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-11T14:30:01Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`. `accepted` is correct and the plan link resolves. Plan
      276 has 1 checked item (planning) and 5 open milestones, so nothing is implemented. The
      request's premises hold: `keiro-ops-http` does not exist; `Keiro.Ops` exports only `main`,
      `mainWithHooks`, `AppHooks`, `OpsAuditConfig`, `emptyAppHooks`, `OpsInvocation`,
      `opsCommandTree`, and `runOpsInvocation`, so `Command`, `commandParser`, `isMutation`, and
      `runCommand` are present internally but still unexported as the plan describes; and
      `verifyExpectedSchemaSession` does not exist in `keiro-migrations`.
completedAt: 2026-11-04T05:28:05Z
resolution: >-
  Plan 276 delivered parser-derived HTTP routes, mutation previews and gates, schema refusal,
  and a bare WAI application.
  Keiro 0.22.0.0 shipped the cohort after the accepted b2be482b release gate.
  Plan 326 retains an exact-version published consumer with a healthy composed
  /keiro/health response; the 0.23.0.0 published consumer repeats that proof.
  Completion reconciles retained evidence; Plan 303 release tracking lags those records.
---

# Improvement Request: Serve the keiro-ops Surface over HTTP

## Status

**Completed; reconciled on 2026-11-04.**
[ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md)
delivered parser-derived HTTP routes, mutation previews and gates, schema refusal, and a bare WAI
application.
[MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
records all six implementation children Complete and their accepted runtime-interference evidence.

The cohort shipped in Keiro 0.22.0.0 (release commit `fb6e3cff`) after the
[final release gate](../../keiro/bench/results/release-gates/0.22.0.0-checks.txt)
passed correctness, all six benchmark guards, native Nix and package checks.
[ExecPlan 326](../plans/326-make-releases-preflighted-resumable-and-isolated.md) retains the
[exact-version published consumer](../../keiro/bench/results/release-gates/workflow-326/published/result.json),
which builds the released packages and serves the composed `/keiro/health` response
with `status: ok` and no schema drift. The
[0.23.0.0 published consumer](../../keiro/bench/results/release-gates/0.23.0.0-20261031T121415Z-60c43662/published/result.json)
repeats that proof (evidence commit `e643c696`). These records satisfy the publication and
consumer gates assigned to
[ExecPlan 303](../plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md);
its older unchecked release milestones do not describe the released state.

Originally proposed by the runtime UI initiative under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`.
The implementation notes below retain the earlier local checkpoints; their pending-release
statements describe those dates, before the release and consumer proof.

## Planning

[ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md) (intention
`intention_01m24fzbdrevnasj0zm1y199vw`) delivers this request as a sister package named
`keiro-ops-http`. Its design answers each requested change directly:

- The read/write split is not a list. Every HTTP request is translated into a `keiro-ops`
  argument vector (path segments are command words and positional arguments, `snake_case`
  query parameters are the command's long options), parsed by the same
  `optparse-applicative` parser the CLI uses, and classified per request with `isMutation`.
  Reads answer `GET` with the command's `jsonValue` as the whole body; mutations answer `POST`.
  Commands added by the sibling plans for IR-29
  ([ExecPlan 274](../plans/274-expose-process-manager-inspection-reads.md)) and IR-30
  ([ExecPlan 275](../plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md))
  become routes without any change to the transport.
- A mutation `POST` without a body returns `{"outcome":"preview","result":…,"cli_reinvocation":…}`
  and performs nothing; only the body `{"confirm":"execute"}` executes and returns
  `{"outcome":"executed","result":…}`. Mutations are disabled by default and refuse with
  HTTP 403 even when confirmed.
- Every request, reads included, runs the schema verification on the host's connection pool
  first and refuses with HTTP 409 `schema_drift` on disagreement; a host-level policy may allow
  drift, in which case the drift count travels in a response header.
- CORS is an explicit allowed-origins list, off by default; errors use the conventions'
  `{"error":{"code","message","details"}}` envelope with a documented code vocabulary.
- `keiro-ops` gains only additional exports (`Command`, `commandParser`, `isMutation`,
  `runCommand`) and `keiro-migrations` a session-level `verifyExpectedSchemaSession`; neither
  gains a web dependency, and the plan includes a build-plan check for acceptance item 5.

Two consequences are recorded for reviewers. Because the transport runs commands in JSON
output mode, the CLI's human-mode typed-name step for `stream hard-delete` and
`pgmq dlq purge` does not apply; those commands are exactly as guarded as
`keiro-ops … --json --force`, and the browser-side typed confirmation belongs to the UI under
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`. The plan does not write the stance ADR or
amend `docs/why-keiro.md`; those remain IR-32's deliverable, and the plan's own ADR records
the transport decisions and cites IR-32.

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


## Implementation evidence (2026-10-20, historical checkpoint)

[ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md) implements
`keiro-ops-http`: parser-derived routes, JSON agreement with the executable,
preview/confirm mutations, default mutation refusal, fail-closed schema checks,
exact-origin CORS, bounded work, dedicated inspection pools, and joined server
shutdown. `keiro-ops-http/test/Main.hs` exercises seeded PostgreSQL state and
real sockets; the initial 20 examples pass. The existing ops and migration
suites pass 51 and 40 examples. DLQ `read` now correctly previews and requires
confirmation because the supported operation reserves messages.

At this checkpoint, full verification, matched interference/retention acceptance
and publication were pending. The Status section records their subsequent completion.
