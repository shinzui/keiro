---
id: 130
slug: make-insert-notifications-survive-crashes-and-document-the-channel-contract
title: "Make insert notifications survive crashes and document the channel contract"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
---

# Superseded: Make insert notifications survive crashes and document the channel contract

This ExecPlan must not be implemented from keiro. It is superseded by the authoritative
pgmq-hs plan:

`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract.md`

The replacement corrects listener lifecycle and libpq encoding, uses the live migration
manifest instead of reserved numbers, and integrates with the official release plan.

## Decision Log

- Decision: Preserve this file only as a redirect to pgmq-hs plan 14.
  Rationale: Notification SQL, migrations, core types, and tests belong in pgmq-hs.
  Date: 2026-07-23

## Revision Note

2026-07-23: Superseded by pgmq-hs plan 14.
