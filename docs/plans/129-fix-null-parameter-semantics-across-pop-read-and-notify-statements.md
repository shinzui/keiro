---
id: 129
slug: fix-null-parameter-semantics-across-pop-read-and-notify-statements
title: "Fix NULL parameter semantics across pop read and notify statements"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
provenance:
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-15T18:17:56Z
      mode: "update"
      note: "Reconcile backlog disposition with delivered scope, superseding plans, and remaining evidence."
---

# Superseded: Fix NULL parameter semantics across pop read and notify statements

> **Backlog disposition — 2026-09-15:** See current Progress and Outcomes & Retrospective for the reconciled scope and evidence. Older instructions are retained as history.


This ExecPlan must not be implemented from keiro. It is superseded by the authoritative
pgmq-hs plan:

`mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`

The replacement includes the existing-test updates required by the `Maybe Message` API and
hands versioning and consumer rollout to the replacement project’s release coordination.

## Decision Log

- Decision (2026-09-15 backlog cleanup): Closed the Keiro redirect in the machine-readable backlog. This closure does not claim upstream work or consumer rollout is complete. Authoritative replacement: `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`.
  Rationale: distinguish delivered work, superseded proposals, and genuine remaining evidence in Mina.

- Decision: Preserve this file only as a redirect to `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`.
  Rationale: API and test implementation belongs in the library's official repository.
  Date: 2026-07-23

## Revision Note

2026-07-23: Superseded by `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`.


## Progress

- [-] Implementation is owned by the authoritative upstream replacement. {disposition=superseded-by, by=mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements}


## Surprises & Discoveries

- (2026-09-15) The checklist lagged the delivery or scope decisions. The reconciliation in Outcomes & Retrospective records the evidence and distinguishes closure from implementation.


## Outcomes & Retrospective

### Backlog reconciliation — 2026-09-15

This plan has no remaining in-scope work. Closed the Keiro redirect in the machine-readable backlog. This closure does not claim upstream work or consumer rollout is complete. Authoritative replacement: `mori://shinzui/pgmq-hs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements`.


Revision note (2026-09-15): reconciled backlog status against recorded delivery and replacement scope; preserved historical evidence and explicit remaining work. No implementation tests were run for this documentation revision.
