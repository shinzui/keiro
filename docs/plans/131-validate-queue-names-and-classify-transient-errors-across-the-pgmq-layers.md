---
id: 131
slug: validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers
title: "Validate queue names and classify transient errors across the pgmq layers"
kind: exec-plan
created_at: 2026-07-23T04:18:42Z
master_plan: "docs/masterplans/21-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review.md"
---

# Superseded: Validate queue names and classify transient errors across the pgmq layers

This ExecPlan must not be implemented from keiro. It is superseded by the authoritative
pgmq-hs plan:

`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers.md`

The replacement preserves topic bindings during mixed-case remediation, covers transient
57P02/57P03 errors, and assigns the complete consumer rollout to pgmq-hs release plan 12.

## Decision Log

- Decision: Preserve this file only as a redirect to pgmq-hs plan 15.
  Rationale: Queue types, decoders, retry classification, and their tests belong in pgmq-hs.
  Date: 2026-07-23

## Revision Note

2026-07-23: Superseded by pgmq-hs plan 15.
