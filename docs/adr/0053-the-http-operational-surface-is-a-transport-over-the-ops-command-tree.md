---
type: Architecture Decision Record
title: The HTTP operational surface is a transport over the ops command tree
description: HTTP reuses the supported command grammar and handlers with bounded inspection work, schema agreement, and explicit mutation confirmation.
timestamp: 2026-10-21T13:47:46Z
docId: ADR-53
status: Accepted
date: 2026-10-20
originatingPlan: docs/plans/276-serve-the-keiro-ops-surface-over-http.md
---

# The HTTP operational surface is a transport over the ops command tree

## Context

[ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
permits inspection in opt-in sister packages, subject to
[ADR-28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md).
A separate route registry would drift from the CLI's capabilities and mutation
classification. A borrowed connection's SQL settings cannot constrain commands
that independently borrow another connection from the same pool.

## Decision

`keiro-ops-http` exports an IO constructor returning a bare WAI application,
a convenience Warp runner, and a database-only executable. Existing packages
acquire no web dependency. It parses requests through `commandParser`, classifies
through `isMutation`, and calls the owning ops runner. Mounted application hooks determine
which commands exist. No command data is reconstructed by transport SQL.

Paths supply words and positional arguments; snake_case queries supply options.
Boolean option metadata is derived once, separately for each command grammar.
Global CLI flags are reserved. GET returns the supported read's JSON value.
POST previews a mutation and executes only for exactly `{"confirm":"execute"}`.
Mutations are off by default. A mutation timeout reports an unknown commit
outcome and never causes an automatic retry.

Every admitted operation verifies schema agreement within its resource budget.
The owner compares live catalog observations against the binary's immutable
expected snapshot in PostgreSQL and returns differences only. Both schemas are
observed in that comparison statement; registry visibility is checked for the
current role. This caches neither live agreement nor role privileges. The
full-snapshot API remains available as a diagnostic and parity oracle. The
large prepared comparison statements must remain shared in optimized code;
allocation evidence is required before removing that sharing boundary.
Drift refusal applies to reads, previews, and confirmed mutations; an explicit
host policy can allow it with a response header. Invalid input, disabled
mutations, and excess admission perform no schema work. Four default slots
have no waiting queue; deadlines cover verification, execution, and encoding.
Request, confirmation, and response bytes are capped. Async cancellation is
propagated and computation unwinds before permits are released. The threaded
RTS timeout manager reuses the request thread on successful work; a deadline
does not allocate fresh work and timer threads for every read. Admission
continues through response delivery, bounding retained encoded bodies when
clients read slowly. The computation deadline ends before delivery; network
exceptions propagate without attempting a second response.

`withOpsInspectionPool` configures search paths and the SQL timeout on every
connection of a dedicated pool. Embedding with a host-supplied/shared pool
requires the same uniform timeout policy and reserved writer capacity. The
transport never changes settings on a runtime connection. It allocates no
recurring database refresh on mount. Integrated runtime interference and
retention evidence remains a release requirement, not an inference from these
bounds.

A command's name does not establish that it is an observation. The released
PGMQ `readDlq` reserves messages for 30 seconds and changes read counts. Thus
`pgmq dlq read` is classified as a mutation, previews supported queue depth by
default, and requires CLI force or HTTP confirmation to reserve rows. The
non-consuming primitives in the local upstream checkout are absent from the
released `mori://shinzui/pgmq-hs/packages/pgmq-effectful` 0.6.1.1; Keiro does not reach into its private tables
or depend on unpublished code. Raw queue browsing remains owned by
`mori://shinzui/pgmq-hs`.

A mount shares its immutable parser grammar and retains at most 64 valid,
read-only parsed commands under the request-byte cap. This reuses pure parsing
only; mutation parsing, schema agreement, registry visibility and authorization
are not cached. Generation rotation and schema changes remain visible on the
next request.

A mount may additionally reuse pure header presentation through the owning
ops runner after an exact current-row comparison in PostgreSQL on every
request. The mount retains at most 32 entries and 1 MiB of charged data,
including lookup keys, full images, JSON, rendered cells and encoded bodies.
Oversized valid responses can be served without retention. Replacements and
evictions remove queue entries as well as map entries; failures, missing rows
and oversized reads invalidate the corresponding presentation. There is no
TTL or refresh task. Live schema checks, response headers, CORS and the final
host byte cap remain fresh. The public OpsResult and mutation envelope stay
unchanged; prepared bytes are paired with the exact successful read result by
the owning runner. A fresh database comparison, rather than an invalidation
hint, authorizes reuse.

Routes are mount-relative and emit no absolute URLs. CORS uses exact allowed
origins, is disabled by default, emits no credential header, and preserves
existing surface CORS headers during composition. The deployment supplies
authentication, authorization, and TLS through a trusted network or reverse proxy.

The delivery amendment selected by
[Plan 318](../plans/318-harden-the-http-operational-surface-against-cross-site-mutations-and-permit-exhaustion.md)
keeps shared admission through delivery and adds a separate configurable delivery deadline
(default 30 seconds). Expiry must unwind delivery, return the permit and terminate the
incomplete response; it must never issue a second response. `/health` shares admission and
may return inspection_busy during saturation. The guarantee is recovery after bounded work
unwinds, not continuous health availability while all slots are held. Real-server connection
termination and cancellation evidence are required before this amendment is implemented;
the current computation-only behavior above is not claimed to have that delivery bound.

## Consequences

New supported commands become routes without a transport edit. A classifier
mistake is a safety defect in every front end and must be repaired in the owning
command, with observable state-change tests. DLQ consumers must add `--force`
when they intend to reserve messages; GET no longer performs that mutation.
The default server binds loopback, and host configuration owns admission and
timeout overrides. SQL LIMIT and pool separation alone do not prove acceptable
runtime interference.

## References

- [HTTP operations runbook](../guides/serve-keiro-ops-over-http.md).
- [MasterPlan 45](../masterplans/45-expose-the-keiro-inspection-surface-for-the-keiro-runtime-ui.md).
- [ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md).
