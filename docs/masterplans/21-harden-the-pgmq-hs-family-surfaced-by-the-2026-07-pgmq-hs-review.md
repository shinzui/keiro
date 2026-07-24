---
id: 21
slug: harden-the-pgmq-hs-family-surfaced-by-the-2026-07-pgmq-hs-review
title: "Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review"
kind: master-plan
created_at: 2026-07-23T04:18:29Z
---

# Superseded: Harden the pgmq-hs family surfaced by the 2026-07 pgmq-hs review

This MasterPlan is superseded and must not be implemented from the keiro repository.

The authoritative MasterPlan now lives in the official pgmq-hs repository:

`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/masterplans/3-harden-the-pgmq-hs-family-surfaced-by-the-2026-07-review.md`

Its child plans are:

- NULL semantics: `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/13-fix-null-parameter-semantics-across-pop-read-and-notify-statements.md`
- Notification crash safety: `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/14-make-insert-notifications-survive-crashes-and-document-the-channel-contract.md`
- Queue validation and error classification: `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/docs/plans/15-validate-queue-names-and-classify-transient-errors-across-the-pgmq-layers.md`

The pgmq-hs repository owns implementation progress, migration numbering, shared-file
coordination, release prerequisites, and plan revisions. Keiro remains an in-scope consumer,
but its bounds and compatibility validation are coordinated by pgmq-hs release plan 12.

## Decision Log

- Decision: Supersede keiro MasterPlan 21 with pgmq-hs MasterPlan 3 and preserve this file as
  a redirect for historical links.
  Rationale: The work changes pgmq-hs APIs, migrations, tests, and release artifacts; its
  source-of-truth plans belong beside that code. The relocated plans also incorporate the
  2026-07-23 validation findings.
  Date: 2026-07-23

## Revision Note

2026-07-23: Replaced the executable plan with this supersession record after relocating and
updating it in the official pgmq-hs repository.
