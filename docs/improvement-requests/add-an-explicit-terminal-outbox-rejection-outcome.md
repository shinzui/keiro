---
type: Improvement Request
title: Add an explicit terminal outbox rejection outcome
description: >-
  Give outbox publishers a public, typed way to report an intentional terminal rejection that
  completes the item without retrying it or misreporting delivery success.
timestamp: 2026-07-30T14:36:35Z
requestId: IR-3
status: proposed
origin: mori://shinzui/shikigami
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:59Z
    document_timestamp: 2026-07-30T14:36:35Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Revalidated against the current PublishOutcome constructors, publisher failure/dead path,
      ordering policies, outbox schema, telemetry, migrations, and downstream canonical origin
      before authoring plan 165.
---

# Improvement Request: Add an Explicit Terminal Outbox Rejection Outcome

## Status

Proposed. This blocks
`mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`'s final
delivery-state implementation; handler-level
truth work can proceed before the release exists. Implementation is now specified by
[plan 165](../plans/165-add-terminal-outbox-publication-rejection-outcomes.md); this request remains
proposed until that plan is implemented and released.

## Context

`Keiro.Outbox.PublishOutcome` in Keiro 0.4.0.1 exposes only `PublishSucceeded` and
`PublishFailed`. Shikigami needs a third semantic result for permanent, intentional refusal:
authorization denial, invalid destination, unsupported declared sink, or another condition that
must be recorded and finalized but must not be retried. Mapping that state to success lies about
delivery; mapping it to failure creates a retry/dead-letter loop for work known to be terminal.

## Requested Change

Add a public terminal outcome, named `PublishRejected` or an equivalent explicit constructor, to
the outbox publishing contract. It must carry a bounded reason/classification suitable for audit
without requiring applications to throw an exception or import an internal module. The Keiro
publisher must finalize the claimed item exactly once, distinguish the outcome in metrics/hooks,
and never schedule it for retry.

Document compatibility for applications that persisted or pattern-matched the old outcome. Add a
released version whose package bounds admit the current Keiro 0.4 family.

## Acceptance

1. A public API test publishes one claimed outbox item as terminally rejected and observes no
   retry, one finalization, and a distinct rejection event/metric.
2. Crash/replay tests prove the terminal transition cannot deliver or finalize twice.
3. Existing success and transient-failure behavior is unchanged.
4. The release notes name the source/API compatibility impact and the tagged release is available
   to downstream solvers.

## Requested Deliverables

- Public outcome type and publisher handling.
- Unit and database integration tests for terminal, transient, and replay cases.
- Migration/compatibility note and a tagged release.
