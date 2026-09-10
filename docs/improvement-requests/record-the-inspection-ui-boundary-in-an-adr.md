---
type: Improvement Request
title: Record the inspection-UI boundary in an ADR
description: >-
  Record in a keiro ADR that an inspection-and-operations surface is a sanctioned, bounded
  exception to the "no parallel workflow engine UI" stance — state browsing and safe operator
  actions over supported APIs, while metrics and traces stay in OpenTelemetry — so accepting
  the keiro-ui endpoint requests is an explicit architectural decision rather than drift.
timestamp: 2026-09-10T03:35:00Z
requestId: IR-32
status: completed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Record the Inspection-UI Boundary in an ADR

## Status

Completed on 2026-09-10.
[ADR 40](../adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md)
(`mori://shinzui/keiro/okf/adrs/concepts/ADR-40`) records the boundary and sanctions the
surface, and `docs/why-keiro.md` §5.6 points at it where the stance is stated.

This request was filed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, under
`mori://shinzui/keiro-ui/plans/5-audit-keiro-and-file-ui-endpoint-improvement-requests`) as a
decision record, not code. It gated nothing mechanically, but the initiative treated it as the
honest precondition for the rest of its keiro requests
(`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-26` through
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-31`). Those requests are now
accepted against a recorded boundary rather than merged around an unamended stance.

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

## Completion evidence (2026-09-10)

1. ADR 40 exists at
   `docs/adr/0040-inspection-surfaces-are-a-bounded-exception-to-the-no-ui-stance.md`. Its
   handle was allocated with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`, the
   bundle index was regenerated with `okf index docs/adr --write`, and the bundle passes
   `okf validate docs/adr --strict --profile-enforce --log-enforce` at 40 concepts. The decision
   sanctions the surface under five conditions: sister-package packaging, ADR-28 discipline on
   the wire, preview-then-confirm mutations disabled by default, push-is-a-hint/poll-is-truth
   feeds, and composition without duplication. Metrics and traces remain OpenTelemetry's, and
   the ADR states that an endpoint may render a supported read's present value but never
   retain, aggregate, chart, or alert on it.
2. `docs/why-keiro.md` §5.6 keeps the no-UI sentence, qualifies it to metrics and traces, and
   links ADR 40 at the point where the stance is stated. The two documents agree, and the ADR
   names itself authoritative if they ever drift.
3. The ADR's decision disposes of IR-26 through IR-31 explicitly: each is accepted against the
   boundary and is implemented, or closed, under the five conditions. The library-read halves
   of IR-28, IR-29, and IR-30 are recorded as ordinary keiro API work whose wire exposure the
   ADR governs.
4. Pointers from the `keiro-ops` documentation: ADR 28's future-console consequence, the
   [operations runbook](../user/operations.md), and the
   [operational console capability](../capabilities/operational-console.md) cite ADR 40.

The sibling requests IR-26 through IR-31 were not edited by this closure. Their in-flight
plans (274 through 278) cite ADR 40 from their own ADRs and evidence sections as they land.
