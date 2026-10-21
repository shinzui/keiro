---
type: Architecture Decision Record
title: Inspection feeds own bounded shared drivers and an active-only wake cursor
description: Inspection sockets share bounded owner-API reads per canonical view and release their wake cursor and tasks when no view remains.
timestamp: 2026-10-21T13:47:46Z
docId: ADR-56
status: Accepted
date: 2026-10-20
originatingPlan: docs/plans/277-publish-websocket-live-feeds-over-keiro-wake.md
---

# Inspection feeds own bounded shared drivers and an active-only wake cursor

## Context

[ADR-40](0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
permits an inspection sister package while protecting ordinary commands and
workers. [ADR-28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
requires supported owner APIs and common representations across CLI and HTTP.
A consumable notification cursor cannot be shared between competing drivers;
an idle duplicated cursor also retains notification history.

## Decision

`keiro-ops-http` owns the socket dialect and drivers. Canonical workflow, timer
and projection-group views read bounded first pages through the same owner APIs
and encoders as poll commands. A feed watches membership in that first page;
removal does not establish deletion or a terminal outcome. Clients page the
paired HTTP read for additional rows.

One driver per canonical view shares initialization, latest successful state,
sequence and encoded frames across subscribers. Initializing and retiring
entries count against view capacity. A refused replacement retains the old
subscription; its queue purge and subscription replacement commit atomically.
Initialization failure never creates an empty snapshot. Refresh failures keep
the last known state and sequence, emit a coalesced error and retry.

While views exist, one pump continuously drains the existing store wake signal
into a bounded epoch counter. Each driver observes that epoch independently;
notifications coalesce while a read runs. The last release joins the driver
and pump and drops the duplicated cursor. Idle mounting creates no wake cursor
or recurring database work. No runtime wake primitive, notification payload,
writer statement or metadata policy is changed.

HTTP reads, upgrades and refreshes share one mount admission budget. Schema
verification, reads, diffing and bounded encoding run inside its deadline.
Refused schema drift stops publication until verification succeeds. The
inspection store uses separately reserved pool capacity and SQL timeouts.
`opsApplicationWithFeeds` requires the same host policy as its feed handle.

Each connection owns one outbound queue and writer, bounded in count and
encoded bytes, including snapshots, controls and in-flight frames. The writer
releases each frame before its next iteration. Making room for an overflow
error may evict another old delta; the error precedes subsequent deltas and
requires snapshot/poll recovery. Blocked sends time out and terminate the
connection. Cleanup joins owned workers and releases all references; close is
idempotent and completes even if a waiting caller is cancelled.

Timer comparisons exclude `due_in_seconds`, while retaining fresh presentation
bodies and database observation time. Projection extra fields are compared too,
so a visible-head change publishes an update without changed rows. Timer views
refresh no more often than every five seconds within the measured 100k-row
ledger envelope. Other cadences remain subject to the shared budget. Fallback
is a scheduling interval, not a worst-case freshness promise under saturation.

Schema agreement remains fresh for each refresh and upgrade. A timestamped success cache
shared by views is not equivalent to that contract: drift or privilege changes between
refreshes must not be admitted merely because a TTL has not expired. Plan 318 retains
per-refresh verification and does not introduce a global handle tick or successful-result
cache. Any future shared-check design must specify observation ordering, cancellation,
failure propagation and bounded ownership before changing this rule.

Semantic equality controls delta publication, not presentation freshness. Even when a timer
has no semantic change, each successful refresh retains its new observation time and current
countdown for subscribers joining afterward. Encoded snapshot reuse based only on unchanged
semantic items is disallowed; the complete presentation must remain current to the latest
successful read. Plan 318 preserves fresh snapshot preparation and tests resubscription
separately from suppression of clock-only deltas.

## Consequences

The socket is a hint-driven rendering of observational reads. A client detects
sequence gaps, treats overflow as desynchronization, and re-subscribes or polls.
The existing Kiroku listener owns connection recovery; feed correctness also
works when no notification is delivered. The sister package alone gains web
socket dependencies. Local behavior and lifecycle checks do not establish the
initiative's composed writer-interference or release gates.
