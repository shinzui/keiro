---
type: Improvement Request
title: Expose aggregate inspection read APIs
description: >-
  Add supported library-level reads for browsing aggregates — list aggregate streams by
  category, hydrate current state for display through the existing snapshot-plus-fold
  machinery, and expose snapshot metadata — and only then endpoints wrapping them, so an
  operator can see what aggregates exist and what state they hold.
timestamp: 2026-09-11T14:30:01Z
requestId: IR-28
status: accepted
origin: mori://shinzui/keiro-ui
plan: docs/plans/278-expose-aggregate-inspection-read-apis.md
---

# Improvement Request: Expose Aggregate Inspection Read APIs

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
Library-first by design: the read APIs are the request's substance, the endpoints (served
under `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`) merely wrap them, per
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28`. Implementation is keiro's downstream work.

Planned on 2026-09-10 as
[ExecPlan 278](../plans/278-expose-aggregate-inspection-read-apis.md) and accepted; it
completes once implementation and release evidence are recorded.

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

## Planning (2026-09-10)

[ExecPlan 278](../plans/278-expose-aggregate-inspection-read-apis.md) (intention
`intention_01m24m6m00ev59wa81shymsktd`) delivers this request in six milestones: a preflight;
a source-reporting hydration primitive plus a clock-consistent snapshot observation in
`keiro`; the inspection module `Keiro.Inspection.Aggregate`; the embedded-only
`keiro-ops aggregate` domain (`types`, `show`, `snapshot`, later `list`) mounted through a
new `AppHooks.aggregates` hook and the `jitsurei` mounting; a release-gated listing
milestone; and documentation with ADR distillation. Its design answers each requested change
directly:

- Item 1b (hydrate for display): state is reconstructed only through the command runner's
  own hydration, an additive `hydrateWithSource` beside `hydrate` that also reports whether
  the state came from a snapshot at a given version or from full replay and why, called with
  seed verification and telemetry disabled. The application supplies the display encoding
  explicitly in an inspector descriptor (derivable from an existing replay-audit target);
  the snapshot codec is never an implicit display format.
- Item 1c (snapshot metadata): snapshot health is observed against the database clock in one
  transaction and reports version, age, events since the snapshot, and the three ADR-3
  discriminators individually with a `compatible` / `incompatible` / `unused` verdict; the
  standalone `keiro-ops snapshot show` gains additive `observed_at` and `age_seconds` keys.
- Item 1a (list by category): listing wraps the prefix-filtered `listStreams` primitive that
  kiroku plan 88 adds for `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-8`
  (prefix `<category>-` selects exactly one category), pages by an opaque cursor minted by the
  shared `Keiro.Inspection.Cursor` codec, and ships only against a released `kiroku-store`
  that exports the primitive. Keiro issues no SQL against kiroku's schema and performs no
  event scans to discover aggregates.
- Item 2 (endpoints): the reads are exposed as read-only `keiro-ops` commands whose JSON is
  rendered by library-owned encoders in snake_case with `items` plus an omitted-on-last-page
  `next_cursor`; the HTTP transport itself is
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26`'s sister package, which
  derives routes from the command tree, so no endpoint code is written here.
- Item 3 (delegation): the served view carries a `history` object naming kiroku as owner
  with the stream name and head version, and no command returns a page of events.

Acceptance mapping: criterion 1 is the gated listing milestone with a two-category
`jitsurei` test and a handler-versus-library JSON agreement test; criterion 2 is an
exhaustive fold-equivalence enumeration against `hydrateFull` on snapshot-enabled and plain
aggregates; criterion 3 renders `status: absent` as a success rather than an error;
criterion 4 is met by construction (only exported owner operations, no Hasql statement in
the inspection module) and checked by review; criterion 5 is met by the `history` reference
and the absence of any event-page command.

Boundaries recorded in the plan: a soft-deleted aggregate is reported with `deleted_at` but
not hydrated; an unknown aggregate fails the command (HTTP 422 under plan 276's mapping)
while a missing snapshot does not; listing the inputs an aggregate accepts next is deferred to
the `EnabledInput` machinery plan 274 is building for process managers. This request is
accepted and completes once implementation and release evidence are recorded.
