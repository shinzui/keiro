---
id: 130
slug: make-insert-notifications-survive-crashes-and-document-the-channel-contract
title: "Make insert notifications survive crashes and document the channel contract"
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

# Superseded: Make insert notifications survive crashes and document the channel contract

> **Backlog disposition — 2026-09-15:** See current Progress and Outcomes & Retrospective for the reconciled scope and evidence. Older instructions are retained as history.


This ExecPlan must not be implemented from keiro. It is superseded by the authoritative
pgmq-hs plan:

`mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`

The replacement corrects listener lifecycle and libpq encoding, uses the live migration
manifest instead of reserved numbers, and integrates with the official release plan.

## Decision Log

- Decision (2026-09-15 backlog cleanup): Closed the Keiro redirect in the machine-readable backlog. This closure does not claim upstream work or consumer rollout is complete. Authoritative replacement: `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`.
  Rationale: distinguish delivered work, superseded proposals, and genuine remaining evidence in Mina.

- Decision: Preserve this file only as a redirect to `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`.
  Rationale: Notification SQL, migrations, core types, and tests belong in pgmq-hs.
  Date: 2026-07-23

## Revision Note

2026-07-23: Superseded by `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`.


## Progress

- [-] Implementation is owned by the authoritative upstream replacement. {disposition=superseded-by, by=mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract}


## Surprises & Discoveries

- (2026-09-15) The checklist lagged the delivery or scope decisions. The reconciliation in Outcomes & Retrospective records the evidence and distinguishes closure from implementation.


## Outcomes & Retrospective

### Backlog reconciliation — 2026-09-15

This plan has no remaining in-scope work. Closed the Keiro redirect in the machine-readable backlog. This closure does not claim upstream work or consumer rollout is complete. Authoritative replacement: `mori://shinzui/pgmq-hs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract`.


Revision note (2026-09-15): reconciled backlog status against recorded delivery and replacement scope; preserved historical evidence and explicit remaining work. No implementation tests were run for this documentation revision.
