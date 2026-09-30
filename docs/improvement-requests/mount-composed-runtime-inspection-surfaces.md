---
type: Improvement Request
title: Mount composed runtime inspection surfaces
description: >-
  Give keiro the mounting story for the composed deployment: one WAI application combining
  keiro's inspection surface with kiroku-metrics', shibuya-metrics', and pgmq-hs's future
  surface under per-surface path prefixes, so an application serves its whole runtime's
  inspection API on one process and one port.
timestamp: 2026-09-30T23:53:54Z
requestId: IR-31
status: accepted
origin: mori://shinzui/keiro-ui
plan: docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md
relatedPlans:
  - docs/masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-15T19:24:42Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`. `accepted` is correct and the absence of a plan link
      is correct. No ExecPlan exists for this request, matching its own Status section. Its
      reasoning still holds: plan 276 has not started, so the `Application` this request would
      mount is not yet fixed, and planning composition ahead of it would be premature. The
      acceptance against ADR 40's fifth condition ("composition, not duplication") is verifiable
      — ADR 40 is present and validates in `docs/adr`.
---

# Improvement Request: Mount Composed Runtime Inspection Surfaces

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Composition is the one cross-cutting concern the initiative's layer-ownership matrix
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`) assigns to keiro: each library owns its
surface, and keiro — already the layer that composes the libraries — owns mounting them into
one process. Implementation is keiro's downstream work.

Accepted (2026-09-15) against the boundary in
[ADR-40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md), whose
fifth condition ("composition, not duplication") sanctions exactly this router-only mounting.
Planned on 2026-09-30 as
[ExecPlan 302](../plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md)
under [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md)
(this request is EP-6), which coordinates IR-26 through IR-31 as one cohort. Keiro's own HTTP
surface is planned as the `keiro-ops-http` sister package in
[ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md), which plan 302 mounts at
the `/keiro` prefix, and its `/ws` feeds in
[ExecPlan 277](../plans/277-publish-websocket-live-feeds-over-keiro-wake.md) sit behind that
prefix as `/keiro/ws`. Plan 302 hard-depends on plan 276 and completes, together with this
request, through the cohort release in
[ExecPlan 303](../plans/303-release-the-keiro-inspection-surface-cohort-and-complete-the-keiro-ui-requests.md).

## Context

A keiro application already links kiroku, shibuya, and pgmq. Once the inspection surfaces
land, the operator of such an application faces either four listeners on four ports (kiroku's
9091, shibuya's 9090, pgmq's future port, keiro's own) — four bind addresses to configure,
four origins for the browser, four things to reverse-proxy — or one composed process. Every
surface in the stack is built for the second option: each is an embeddable WAI `Application`
by the sister-package rule (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`), exportable
precisely so a host can mount several under one server. What no repository owns yet is the
composition itself: the path-prefix layout, the shared server configuration, and the
convenience API that makes "one port, whole runtime" a few lines in an application.

The surfaces being composed are the ones the initiative has requested across the stack:
keiro's own (`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`,
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-27`), kiroku-metrics as it stands
plus its requested extensions
(`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8` through
`mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-13`), shibuya-metrics as it stands
plus `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-3` through
`mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-5`, and pgmq-hs's requested
sister package (`mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3`). None of
those requests is a prerequisite for accepting this one — the mounting story composes
whatever subset exists, starting with the two surfaces that ship today.

## Requested Change

1. A composition API in keiro's inspection sister package (or a small dedicated package —
   keiro's choice): given the host's mounted surfaces — keiro's own `Application`,
   kiroku-metrics' `Application`, shibuya-metrics' `Application`, pgmq's when it exists —
   produce one WAI `Application` routing per-surface path prefixes (for example `/keiro/…`,
   `/kiroku/…`, `/shibuya/…`, `/pgmq/…`; exact prefixes are keiro's to finalize and document
   as stable).
2. WebSocket upgrades route through the same prefixes (each surface's WS endpoints work
   unchanged behind its prefix).
3. One place to configure the cross-cutting posture for the composed server: bind
   address/port and CORS allowed-origins applied uniformly, per the conventions (project
   `mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`,
   artifact-level URI pending) — while each mounted surface keeps its own behavior otherwise.
4. Composition only: no re-serving, no response rewriting, no keiro-owned duplication of any
   lower-layer endpoint (`mori://shinzui/keiro/okf/adrs/concepts/ADR-28` schema-ownership
   discipline extended to the wire — the composed app is a router, not a proxy that reshapes).
5. A documented example: a jitsurei-style application serving the composed surface on one
   port.

## Acceptance

1. An example application mounts keiro's surface and kiroku-metrics' surface into one process
   on one port; `GET /kiroku/health` and `GET /keiro/...` (final prefixes as documented) both
   answer, byte-identical to the same routes served standalone.
2. A WebSocket client connects through a prefix (for example kiroku's `/ws/events` behind
   `/kiroku`) and the protocol works unchanged.
3. With CORS configured once on the composed server, a browser page on an allowed origin can
   call routes on every mounted surface; with it unconfigured, no CORS headers appear
   anywhere.
4. Adding or omitting a surface at mount time changes only which prefixes answer — mounted
   surfaces are unaffected by absent ones.
5. Inspection of the composition code shows routing only: no endpoint of any mounted surface
   is reimplemented or reshaped by keiro.

## Requested Deliverables

The composition API with its stable prefix layout documented, WS-through-prefix support, the
uniform CORS/bind configuration, tests for the acceptance criteria, and the documented
example application.

## Planning (2026-09-30)

[ExecPlan 302](../plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md)
delivers this request inside the `keiro-ops-http` package as the module
`Keiro.Ops.Http.Compose`, chosen over a dedicated package because the API is generic over WAI
`Application` values and needs no dependency on any sibling metrics package. Its design answers
each requested change directly:

- Item 1: `composeSurfaces :: ComposeConfig -> [MountedSurface] -> Either ComposeError Application`
  mounts any surfaces under the stable prefixes `keiro`, `kiroku`, `shibuya`, and `pgmq`
  (exported constants; a host may also use any other single lowercase segment). The router
  forwards a request whose first segment matches a mounted prefix with both `pathInfo` and
  `rawPathInfo` stripped of the prefix and every other field untouched, answers `GET /` with the
  list of mounted prefixes, and answers an unmounted prefix with the conventions' error envelope
  and code `surface_not_mounted`.
- Item 2: because `wai-websockets` derives the WebSocket request path from `rawPathInfo`, the
  raw-path rewrite is what makes every mounted `/ws` endpoint work unchanged behind its prefix;
  a database-free test proves it over a real socket, and the end-to-end tests drive
  kiroku-metrics' `/kiroku/ws/metrics` and, once plan 277 lands, keiro's `/keiro/ws`.
- Item 3: bind address, port, and request timeout come from plan 276's `withOpsHttpServer`; CORS
  is one explicit allowed-origins list on `ComposeConfig`, off by default, applied by a
  composed-layer middleware that answers preflights for allowed origins and adds
  `Access-Control-Allow-Origin` only to responses that do not already carry it, so a surface
  mounted with its own CORS on is never double-labelled and one mounted with it off is still
  reachable.
- Item 4: the module names no route of any mounted surface (a test reads the source and asserts
  it), imports no store or sibling package, and reshapes no response; the ADR the plan writes
  records the composition boundary as prefix routing only.
- Item 5: a flag-guarded example executable, `keiro-ops-http-compose-example`, mounts keiro's
  database-only surface and kiroku-metrics on one port, and the runbook
  `docs/guides/compose-runtime-inspection-surfaces.md` documents the prefixes as stable, the
  single-origin console deployment, and how shibuya's and pgmq's surfaces mount once their
  packages export a bare `Application` (neither does on 2026-09-30; shibuya's is planned under
  `mori://shinzui/shibuya/masterplans/7-browser-ready-processor-inspection-and-control-surface`
  and pgmq-hs's is requested by `mori://shinzui/pgmq-hs/okf/improvement-requests/concepts/IR-3`).

Acceptance criteria 1 through 5 map to named test cases in the plan's Validation and Acceptance
section. This request stays `accepted` until implementation starts, and completes through
plan 303 once the release that carries the module is on Hackage.
