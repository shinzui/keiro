---
id: 129
slug: fix-null-parameter-semantics-across-pop-read-and-notify-statements
title: "Fix NULL parameter semantics across pop read and notify statements"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
---

# Superseded: Fix NULL parameter semantics across pop read and notify statements

This ExecPlan must not be implemented from keiro. It is superseded by the authoritative
pgmq-hs plan:

`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements.md`

The replacement includes the existing-test updates required by the `Maybe Message` API and
hands versioning and consumer rollout to pgmq-hs release plan 12.

## Decision Log

- Decision: Preserve this file only as a redirect to pgmq-hs plan 13.
  Rationale: API and test implementation belongs in the library's official repository.
  Date: 2026-07-23

## Revision Note

2026-07-23: Superseded by pgmq-hs plan 13.
