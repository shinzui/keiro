---
type: Architecture Decision Record
title: Compose allocated inspection applications without changing their routes
description: A pure prefix router mounts owner applications and preserves raw route spelling, shared admission and lifecycle ownership.
timestamp: 2026-10-21T03:21:33Z
docId: ADR-57
status: Accepted
date: 2026-10-20
originatingPlan: docs/plans/302-mount-composed-runtime-inspection-surfaces-under-one-port.md
---

# Compose allocated inspection applications without changing their routes

## Context

[ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
permits mounting sibling inspection surfaces. Reconstructing their routes would
split ownership; constructing applications per request would recreate admission
budgets and resource handles. WebSocket upgrades use the raw WAI request path.

## Decision

`Keiro.Ops.Http.Compose` takes already allocated WAI applications and owns no
stores, listeners, SQL, background tasks or response buffers. It precomputes the
mount table and root discovery response. The stable single-segment prefixes are
`keiro`, `kiroku`, `shibuya` and `pgmq`; validated custom prefixes are supported.
Duplicate or empty mount sets fail at construction. Missing surfaces return
`surface_not_mounted` without probing another service.

Strip exactly the first encoded path segment after matching its decoded name.
Rewrite both `pathInfo` and `rawPathInfo`, preserving remaining raw bytes, query
strings, interior empty segments and route trailing slashes. Normalize only the
mount root to `/`. Reject inconsistent synthetic raw/decoded paths. Responses,
including streaming bodies and upgrades, pass through unchanged.

Reuse the standalone exact-origin CORS middleware at the outer layer; it adds
only absent response headers. Sharing this implementation avoids policy drift.
Allowed preflight headers follow `Access-Control-Request-Headers`. Hosts pass
the same origin policy to each owner's WebSocket check. Keiro HTTP and feeds
retain their one shared admission budget and dedicated inspection pool.

The example uses the released public application from
`mori://shinzui/kiroku/packages/kiroku-metrics`, allocated once. The dependency
stays in tests and a manual default-off example flag. No sibling HTTP package
enters the composition library or ordinary runtime library closure.

## Consequences

Mounting changes only discovery and prefix dispatch. Each owner retains its
wire format, read limits and connection cleanup. The existing Warp runner owns
the one listener; hosts release it before feed handles and inspection stores.
Composition supplies no authentication: use a trusted network or authenticating
proxy. Local correctness checks do not establish the separate core-runtime
interference gate.
