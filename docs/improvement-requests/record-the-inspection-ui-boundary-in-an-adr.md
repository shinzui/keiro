---
type: Improvement Request
title: Record the inspection-UI boundary in an ADR
description: >-
  Record in a keiro ADR that an inspection-and-operations surface is a sanctioned, bounded
  exception to the "no parallel workflow engine UI" stance — state browsing and safe operator
  actions over supported APIs, while metrics and traces stay in OpenTelemetry — so accepting
  the keiro-ui endpoint requests is an explicit architectural decision rather than drift.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-32
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Record the Inspection-UI Boundary in an ADR

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`).
This request asks for a decision record, not code. It gates nothing mechanically, but the
initiative treats it as the honest precondition for the rest of its keiro requests
(`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26` through
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`): they should be accepted
against a recorded boundary, or rejected against one — not merged around an unamended stance.

## Context

`docs/why-keiro.md` states, as a selling point: applications observe keiro through
OpenTelemetry in the dashboards they already run — "There is no parallel \"workflow engine
UI\" to maintain." The stance has real content: keiro is a library, not a server; there is no
keiro process to host a console; and the OTel-first posture keeps keiro out of the dashboard
business.

The keiro-ui initiative's requests would erode that stance silently if filed without comment
— which is why this request exists. The reframing the initiative proposes is honest rather
than rhetorical: OpenTelemetry covers *metrics and traces*; it cannot browse an aggregate's
state, list stuck workflow instances with their leases, show a process manager's journal, or
carry a previewed, confirmed operator action. Those are *state inspection* and *operations*
— the business `keiro-ops` is already in, as a CLI. The requested HTTP surface
(IR-26..IR-31) is `keiro-ops`'s discipline on a transport a browser can reach, not a parallel
observability stack: metrics and traces stay in OTel dashboards, and the inspection surface
does not grow gauges, histograms, or trace views.

The stack precedent for recording exactly this kind of boundary is
`mori://shinzui/keiro/okf/adrs/concepts/ADR-28` (operator commands wrap supported APIs) and
the sister-package rule the whole runtime follows
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-4`).

## Requested Change

A keiro ADR — allocated, validated, and indexed by keiro's own `docs/adr/` tooling — that
records:

1. The boundary: keiro sanctions an inspection-and-operations surface — state browsing and
   safe operator actions over supported library APIs — as a bounded exception to the no-UI
   stance; metrics and traces remain OpenTelemetry's, and the surface must not duplicate
   them.
2. The conditions that keep it bounded: sister-package packaging (no web dependency in
   existing packages), ADR-28 discipline (wrap supported APIs, fixed reporting vocabulary),
   the preview/confirm gate on mutations, and the push-is-a-hint/poll-is-truth rule for live
   feeds.
3. The relationship to the stance text: `docs/why-keiro.md` is amended to point at the ADR —
   the sentence may stand with a qualifier or be reworded, keiro's choice, but the document
   and the ADR must agree.

If keiro instead *rejects* the boundary, recording that decision in an ADR is an equally
valid outcome of this request: the initiative would rather build against a recorded "no" than
an ambiguous silence.

## Acceptance

1. The ADR exists in keiro's `docs/adr/` bundle, passes keiro's own bundle validation, and is
   citable by canonical handle (`mori://shinzui/keiro/okf/adrs/concepts/ADR-N`).
2. `docs/why-keiro.md` references the ADR at the point where the no-UI stance is stated, and
   the two do not contradict each other.
3. The ADR's decision explicitly disposes of IR-26..IR-31's premise — sanctioning the
   bounded surface, or rejecting it — so each of those requests can be accepted or closed
   against a recorded decision.

## Requested Deliverables

The ADR (with its bundle bookkeeping), the `docs/why-keiro.md` amendment, and — encouraged
but keiro's choice — a pointer to the ADR from the `keiro-ops` documentation, since the CLI
is the discipline the surface extends.
