---
type: Improvement Request
title: Add an explicit terminal outbox rejection outcome
description: >-
  Give outbox publishers a public, typed way to report an intentional terminal rejection that
  completes the item without retrying it or misreporting delivery success.
timestamp: 2026-09-11T14:30:01Z
requestId: IR-3
status: completed
origin: mori://shinzui/shikigami
plan: docs/plans/165-add-terminal-outbox-publication-rejection-outcomes.md
completedAt: 2026-08-21T16:31:33Z
resolution: >-
  Plan 165 delivered PublishRejected, the OutboxRejected terminal status, conditional
  markOutboxRejectedTx finalization, the keiro.outbox.rejected counter, migration 31, and ADR-37.
  Implementation commit c237424a is contained in the keiro-0.14.0.0 tag, and keiro 0.14.0.0 is
  published on Hackage with release notes naming the compatibility impact.
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
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-09-16T04:45:00Z
    document_timestamp: 2026-09-11T14:30:01Z
    scope: completion-evidence
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    effort: high
    context: >-
      Bundle refresh at Keiro `708aa215`. Plan 165 is complete (5/5 progress items checked, none
      open) and its link resolves; `completed` is the accurate status. `OutboxRejected` is
      exported from `Keiro.Outbox.Types`, and the Hackage `preferred` endpoint lists keiro
      0.14.0.0, matching the recorded resolution. Scope was status, link integrity, and presence
      of the delivered capability in the current tree; the shipped behavior was not re-derived
      from a test run.
---

# Improvement Request: Add an Explicit Terminal Outbox Rejection Outcome

## Status

Completed. [Plan 165](../plans/165-add-terminal-outbox-publication-rejection-outcomes.md)
implemented the terminal rejection outcome, and it shipped in Keiro 0.14.0.0 (2026-08-21). This
request had blocked
`mori://shinzui/shikigami/plans/19-sink-delivery-truth-and-downstream-idempotency`'s final
delivery-state implementation; that consumer can now bind to the released API.

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
