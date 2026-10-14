---
type: Improvement Request
title: Classify removal of a command together with its emitted event in keiro-dsl diff
description: >-
  keiro-dsl diff --since GIT-REF fails with an aggregate fold output resolution error instead of a
  classification when one change removes a command, the event it emitted, and the state it led
  to, so a consumer's generated-code gate cannot run on that change until it is committed.
timestamp: 2026-10-14T15:35:26Z
requestId: IR-50
status: completed
completedAt: 2026-10-14T15:35:26Z
origin: mori://tan/notification-hub
plan: docs/plans/314-fix-ir-50-command-and-event-removal-diff-classification.md
acceptanceCriteria:
  - id: AC-1
    statement: Removing a command, the event it emits, and the state that event leads to in one spec change is classified by diff --since GIT-REF as a breaking aggregate change naming the removed command, event, and state, with exit status governed by the usual gates.
    verification: A keiro-dsl diff fixture whose old spec has the three declarations and whose new spec lacks them, asserting the classification and the absence of a fold resolution error.
  - id: AC-2
    statement: The replay-impact report for that change says which recorded event types no longer decode and which streams are affected, in the same shape it uses for a renamed or retyped event.
    verification: The same fixture's --replay-impact-out output compared against a golden file.
  - id: AC-3
    statement: A fold-surface fingerprint resolves each spec's transition outputs against that spec's own event set, so an old transition is never resolved against the new event list.
    verification: A unit test on the fold fingerprint over the old and new specs of the fixture.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-24T14:45:00Z
    document_timestamp: 2026-09-24T14:45:00Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-fable-5-1
    effort: high
    context: >-
      The authoring model's own verification, not an independent review: the failure was reproduced
      with keiro-dsl 0.18.0.0 (tag keiro-dsl-0.18.0.0) on mori://tan/notification-hub, the message
      traced to FoldEventOutputResolutionFailed in keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs and
      OutputEventMissing in keiro-dsl/src/Keiro/Dsl/EventOutput.hs at commit f48a5114, and check and
      scaffold were confirmed to accept the same spec.
---

# Classify removal of a command together with its emitted event in keiro-dsl diff

## Status

Completed by [ExecPlan 314](../plans/314-fix-ir-50-command-and-event-removal-diff-classification.md)
and implementation commit `3cd98914` (unreleased). Each valid revision resolves
against its own declarations. Single-source and workspace removals produce the
breaking event finding, removed command/state details, and both JSON reports before
the normal compatibility gate exits 1. A replay-only remedy whose declarations
were deleted is withheld.

The Language 6 fixtures `keiro-dsl/test/fixtures/ir50-removal-old.keiro` and
`keiro-dsl/test/fixtures/ir50-removal-new.keiro` independently pass check and fold
resolution. The `IR-50 removal diff` test group passes all ten examples, including
same-state removal, deleted event-only types, dependency changes, invalid-input
refusal, and both CLI paths. The replay report matches
`keiro-dsl/test/fixtures/ir50-removal-replay.json`; same-state removal selects only
`RetiredEvent`. All 58 DSL suites pass (858 main-suite examples), the clean corpus
check passes all 56 invocations without generated-file churn, and API, inventory,
ADR, and user-documentation gates pass. This closes the reporting defect; it does
not certify a consumer's historical-data migration or deploy the breaking removal.

## Context

Plan 81 of MasterPlan 14 in `mori://tan/notification-hub` removed the rendered lifecycle from its
Notification aggregate in one spec change: the `MarkRendered` command, the `NotificationRendered`
event it emitted, and the `NotifRendered` state that event led to, with the two transitions that
left that state rewired to `NotifRequested`. `keiro-dsl check --min-language 6` accepted the spec
and `scaffold` regenerated the workspace, but the repository's generated-code gate runs
`keiro-dsl diff <workspace> --since HEAD`, and that command failed before producing any
classification:

```text
aggregate fold output resolution failed for 'Notification.MarkRendered' emitting 'NotificationRendered': OutputEventMissing "NotificationRendered"
```

The old spec declares both the command and the event, so resolving the old spec's transition
outputs against the old spec's events would succeed. The message comes from
`FoldEventOutputResolutionFailed` in `keiro-dsl/src/Keiro/Dsl/FoldFingerprint.hs`, which wraps
`OutputEventMissing` from `keiro-dsl/src/Keiro/Dsl/EventOutput.hs`; the observed behavior is that
the old transition is resolved against an event set that no longer contains the event. Removing a
projection target in the same repository (`CatalogTargetRemoved`, plan 83) was classified as
breaking and reported cleanly, which is what a consumer expects for an aggregate removal too.

The consumer's workaround is to commit the change and rely on `--since HEAD` then comparing equal
specs, which means the gate never classifies the change it was written to classify. `--explain`
repeats the same error.

## Request

Make `diff` classify the removal of a command together with its emitted event and target state as a
breaking aggregate change, naming the removed declarations, and produce the replay-impact report
for the stored events that no longer decode, in the shape used for event renames and retypes. To
do that, resolve each spec's fold surface against its own declarations, so that fingerprinting the
old aggregate never consults the new event list. If a fold fingerprint genuinely cannot be
computed for a spec, the diagnostic should say which spec (old or new) and why, rather than
naming an event that the reported spec does declare.

## What stays out

No change to `check`, `scaffold`, or the ledger format is requested, and the classification's
severity (breaking) is not in question; only that it is produced.
