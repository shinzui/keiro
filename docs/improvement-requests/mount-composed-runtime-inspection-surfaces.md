---
type: Improvement Request
title: Mount composed runtime inspection surfaces
description: >-
  Give keiro the mounting story for the composed deployment: one WAI application combining
  keiro's inspection surface with kiroku-metrics', shibuya-metrics', and pgmq-hs's future
  surface under per-surface path prefixes, so an application serves its whole runtime's
  inspection API on one process and one port.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-31
status: proposed
origin: mori://shinzui/keiro-ui
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
