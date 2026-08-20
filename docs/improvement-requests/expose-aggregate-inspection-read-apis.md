---
type: Improvement Request
title: Expose aggregate inspection read APIs
description: >-
  Add supported library-level reads for browsing aggregates — list aggregate streams by
  category, hydrate current state for display through the existing snapshot-plus-fold
  machinery, and expose snapshot metadata — and only then endpoints wrapping them, so an
  operator can see what aggregates exist and what state they hold.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-28
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose Aggregate Inspection Read APIs

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Library-first by design: the read APIs are the request's substance, the endpoints (served
under `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`) merely wrap them, per
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`. Implementation is keiro's downstream work.

## Context

The aggregate is keiro's central application concept, and it is invisible to operators.
Aggregate state is folded from kiroku events on demand, optionally accelerated through
advisory snapshots in `keiro_snapshots` (the `Hydrated` path in `keiro/src/Keiro/Command.hs`),
and no keiro read API lists aggregate streams or hydrates state for display. An operator
debugging "why did this command get rejected" needs to see the aggregate's current state; an
operator exploring a system needs to list what aggregates exist in a category. Today both
require Haskell.

The precedent for "someone outside the process needs to see keiro state safely" is
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-22`, which produced the guarded
external-read discipline (`mori://shinzui/keiro/okf/adrs/concepts/ADR-35`,
`mori://shinzui/keiro/okf/adrs/concepts/ADR-36`). This request is the same story for
aggregates, over the in-process library surface.

Two boundaries scope it:

- **Raw stream and event browsing is kiroku's**, not keiro's: the initiative has filed
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8` for exactly that (list/search
  streams, categories, `$all` paging, event-by-id). keiro's aggregate views add framework
  semantics — the fold, the snapshot, the aggregate identity — and delegate raw event display
  to kiroku's surface. Nothing here duplicates a kiroku endpoint.
- **Name resolution**: `mori://shinzui/kiroku/okf/adrs/concepts/ADR-1` — events fetched
  across streams carry surrogate stream ids; any keiro view that shows an aggregate's recent
  events must budget the batch name-resolution step (or delegate that display to kiroku's
  endpoints entirely).

## Requested Change

1. Library-level reads in the owning packages (`keiro`/`keiro-core`):
   a. list aggregate streams by category, cursor-paginated, with per-aggregate identity and
      current version;
   b. hydrate an aggregate's current state for display, reusing the existing
      snapshot-plus-fold machinery (the `Hydrated` path) so inspection reads cost what
      command-side hydration costs, with the state rendered through a supported
      display/JSON encoding rather than exposing internal representations accidentally;
   c. expose snapshot metadata from `keiro_snapshots` (which aggregate, version, age) so an
      operator can see snapshot health.
2. Endpoints in the IR-26 sister package wrapping exactly those reads, following the
   initiative's wire conventions (project `mori://shinzui/keiro-ui`, path
   `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending): cursor
   pagination, snake_case, structured errors, ADR-28 vocabulary.
3. Delegation stated in the served payloads: aggregate detail views link to kiroku-owned
   stream/event browsing (kiroku IR-8's endpoints) for raw history rather than re-serving
   event pages from keiro.

## Acceptance

1. With a test application holding aggregates in two categories, the list read returns each
   category's aggregates with identity and version, paged by cursor, and the corresponding
   endpoint serves the same page as JSON.
2. Hydrating a chosen aggregate returns state equal to what the command path would fold for
   the same aggregate at the same version (asserted by test), whether or not a snapshot
   exists, and the endpoint serves it.
3. Snapshot metadata for an aggregate with a snapshot shows the snapshot's version and age;
   for one without, the read says so explicitly rather than erroring.
4. No new read touches kiroku's or keiro's private schemas ad hoc: everything goes through
   supported library operations (inspectable), per ADR-28.
5. The aggregate views expose no raw event-page endpoint — raw history is delegated to
   kiroku's browsing surface by reference.

## Requested Deliverables

The library reads with Haddock and tests (including the fold-equivalence property), the
wrapping endpoints with transcripts in documentation, and the delegation links in the served
payloads.
