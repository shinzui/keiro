---
type: Architecture Decision Record
title: Inspection surfaces are a bounded exception to the no-UI stance
description: Keiro sanctions state browsing and safe operator actions over supported library APIs in opt-in sister packages, while metrics and traces stay in OpenTelemetry and no keiro package grows a dashboard, a server process, or a parallel observability stack.
timestamp: 2026-09-10T03:35:00Z
docId: ADR-40
status: Accepted
date: 2026-09-10
---

# Inspection surfaces are a bounded exception to the no-UI stance

## Context

[Why keiro §5.6](../why-keiro.md) sells the absence of a console. Keiro is a
library, not a server; spans, gauges, and histograms flow through OpenTelemetry
into the dashboards an operator already runs; there is no parallel workflow
engine UI to maintain. The stance has real content. No keiro package listens on
a network port, no keiro process exists to host a console, and keiro does not
compete with the operator's observability stack.

The keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`) filed
six endpoint requests against keiro,
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26` through
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`, and a seventh,
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-32`, asking that
keiro decide the stance explicitly before the six are merged or refused. The
requests do not ask for dashboards. They ask for what OpenTelemetry cannot
express: an aggregate's current state, a workflow instance with its lease and
attempt history, a process manager's journal and pending timers, a projection
group's serving status, and a previewed, confirmed operator action. Those are
state inspection and operations. Keiro is already in that business through
`keiro-ops`, whose command tree wraps supported library operations under
[ADR 28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md);
the only thing a browser lacks is a transport it can reach.

The stack already records how such surfaces are packaged and how live feeds
behave. Kiroku and shibuya ship their HTTP surfaces as sister packages so that
adopting a library never means adopting a web server
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`). Every endpoint lives in
the project that owns the concept, and keiro composes lower layers rather than
re-serving them (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`). Push is a
hint and poll is truth (`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`).
The browser console is read-only first, and every mutation it ever offers
rides an owning-repository gate
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7`). Merging the six requests
without a keiro decision would erode a published stance silently; refusing them
without one would leave the initiative building against an ambiguous silence.

## Decision

Keiro sanctions an inspection-and-operations surface as a bounded exception to
the no-UI stance. The surface exposes state browsing and safe operator actions
over supported library APIs on a transport a browser can reach. It is not, and
may not become, a parallel observability stack. Metrics, traces, histograms,
time-series storage, alerting, and trace views remain OpenTelemetry's. An
endpoint may render the present value a supported read returns, including a
global position distance; it may not retain, aggregate, chart, or alert on
those values over time, and no endpoint duplicates a signal `Keiro.Telemetry`
already exports. When a requested view needs a rate, a latency distribution,
or a span tree, the answer is an OpenTelemetry instrument, not an endpoint.

Five conditions keep the exception bounded. An endpoint that fails any of them
is refused or routed back to the owning mechanism, whichever request asked for
it.

1. **Sister-package packaging.** No existing keiro package gains a web
   dependency. Each HTTP or WebSocket surface is a dedicated package that
   depends on the core and exports the bare WAI `Application` plus a
   convenience runner. Hosting is the application's choice; keiro ships no
   listener, no daemon, and no bundled browser application. The browser
   console itself is `mori://shinzui/keiro-ui`'s deliverable. Keiro's stops at
   the embeddable application and its documented wire contract.
2. **ADR 28 discipline on the wire.** Every endpoint is a rendering of a
   supported operation: a `keiro-ops` command or an exported read from the
   library that owns the state. Missing primitives are added and tested in the
   owning library before any endpoint exposes them. No endpoint issues ad hoc
   SQL, reaches into kiroku's or pgmq's private schemas, or reports positions
   outside ADR 28's fixed vocabulary (`store_position`, `visible_store_head`,
   global position distance; never lag or backlog). The read/write split is
   derived mechanically from `isMutation`, never from a hand-maintained list.
3. **Preview, then confirm.** A mutation reached over the surface performs
   only the supported preview until an explicit confirmation arrives, reports
   the exact confirmed re-invocation, and then executes the same supported
   mutation the CLI's `--force` path executes. Schema drift is refused
   fail-closed across the surface by default; a host may admit drift only by
   explicit policy, never silently. Whether mutations are mounted at all is
   host configuration, disabled by default. The transport adds reach, never
   capability, and it adds no authentication of its own: who may act is the
   deployment's concern, and payload decoding and authorization stay with
   application adapters as ADR 28 already requires.
4. **Push is a hint; poll is truth.** Every live feed is paired with an
   authoritative read whose result is the feed's truth; `Keiro.Wake`
   notifications only shorten the time to the next read. A feed's items are
   identical to the paired read's rendering, no endpoint exists in push-only
   form, and a lost `LISTEN` connection degrades to bounded polling rather
   than to silence.
5. **Composition, not duplication.** Keiro may mount kiroku's, shibuya's, and
   pgmq's surfaces beside its own under stable path prefixes, because it is
   already the layer that composes those libraries. The composed application
   is a router. It never re-serves, reshapes, or re-implements an endpoint
   another library owns, and raw stream and event browsing stays kiroku's.

This decision disposes of the initiative's premise. IR-26 (the HTTP transport
over `keiro-ops`), IR-27 (WebSocket feeds over `Keiro.Wake`), IR-28 (aggregate
inspection reads), IR-29 (process-manager inspection reads), IR-30
(cursor-paged workflow reads), and IR-31 (composed mounting) are accepted
against this boundary and are implemented, or closed, under these five
conditions. The library-read halves of IR-28, IR-29, and IR-30 are ordinary
keiro API work that would be sound without any surface; this decision governs
their exposure on the wire. Plans that implement them record their transport
and feed decisions in their own ADRs beneath this one.

[Why keiro §5.6](../why-keiro.md) is amended to say what the stance now
means: no parallel observability stack and no server process, with state
inspection and operations sanctioned here as an opt-in sister package. The
stance text and this record must agree. When they drift, this record is
authoritative and the stance text is corrected.

## Consequences

- The selling point narrows rather than disappears. Keiro still ships no
  dashboard, no time-series store, and no process to host a console. What it
  adds is an embeddable, opt-in transport for the operator discipline
  `keiro-ops` already carries.
- An endpoint request is reviewed against five checkable conditions instead
  of against a sentence. A request that needs a gauge, a histogram, or a trace
  view is refused and routed to `Keiro.Telemetry`; a request that needs a
  private table is refused and routed to the owning library's public API.
- Sister packages cost lockstep versioning and releases alongside the rest of
  the package set. That cost is accepted so that adopting keiro never means
  adopting a web server.
- Mounting mutation routes widens an application's attack surface. The default
  is read-only, mutations require both host opt-in and per-request
  confirmation, and the surface inherits the CLI's schema-drift refusal, so it
  is exactly as dangerous as `keiro-ops --json --force` and no more.
- Widening the exception, for example with a metrics endpoint, a bundled
  console, or a keiro-owned listener, is a new decision that supersedes this
  one, never an incremental amendment.
- ADR 28's consequence that a future console reuses the command handlers
  without permission to bypass the library boundary now has a concrete
  instance and points here, as do the
  [operations runbook](../user/operations.md) and the
  [operational console capability](../capabilities/operational-console.md).

## References

- `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-32` requested
  this record;
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26` through
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31` are the
  requests it disposes of.
- [ADR 28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
  is the discipline this surface extends; conditions 2 and 3 restate it for
  the wire.
- `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-3`,
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`, and
  `mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-7` record the stack-wide
  ownership, poll-is-truth, sister-package, and read-only-first rules that
  conditions 1, 4, and 5 adopt. The wire conventions live in project
  `mori://shinzui/keiro-ui` at `docs/architecture/inspection-api-conventions.md`
  (artifact-level URI pending).
- [ExecPlan 276](../plans/276-serve-the-keiro-ops-surface-over-http.md),
  [ExecPlan 277](../plans/277-publish-websocket-live-feeds-over-keiro-wake.md),
  [ExecPlan 278](../plans/278-expose-aggregate-inspection-read-apis.md),
  [ExecPlan 275](../plans/275-add-cursor-paged-workflow-inspection-reads-for-the-http-surface.md),
  and [ExecPlan 274](../plans/274-expose-process-manager-inspection-reads.md)
  implement IR-26, IR-27, IR-28, IR-30, and IR-29 under this boundary.
