---
type: Improvement Request
title: Return typed domain command outcomes and rejection details
description: >-
  Preserve application-defined rejection/no-op reasons and emitted domain outcomes instead of
  reducing all unmatched business decisions to generic CommandRejected metadata.
timestamp: 2026-07-31T15:03:55Z
requestId: IR-7
status: proposed
origin: mori://shinzui/keiro
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:55Z
    document_timestamp: 2026-07-31T15:03:55Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of Keiro.Command.CommandResult and CommandError after ambiguity and
      replay witnesses were hardened. Business rejection remains a generic constructor and no-op
      carries only zero append metadata.
---

# Improvement Request: Return Typed Domain Command Outcomes and Rejection Details

## Status

Runtime/API delivery is implemented by
[Plan 231](../plans/231-add-typed-domain-command-outcomes.md): handwritten
aggregates now have typed direct, SQL, projection, router, process-manager, and
bounded-telemetry outcomes. [Plan 232](../plans/232-add-typed-domain-outcomes-to-the-dsl.md)
has now delivered candidate language-5 syntax, exhaustive checking, generated
handlers, exact-reason conformance, mutation coverage, and fixed-size scaling
fixtures. The request remains proposed rather than completed only because the
shared quiet-host latency/allocation/residency acceptance and committed DSL
generation baseline remain pending; no baseline was changed under the current
host load.

## Progress

- Runtime contract: `DomainDecision`, `DomainCommandOutcome`,
  `SilentCommandContext`, `SilentDomainDecision`, and `DomainCommandHandler`
  are public, additive interfaces.
- Execution: direct, transactional, inline/catalog projection, router, and
  process-manager runners preserve typed outcomes and final-retry authority.
- Policy: selected rejection/no-op is successful and side-effect-free;
  unmatched and infrastructure failures remain `CommandError`.
- Operations: coordinator workers acknowledge typed silent decisions normally,
  drop handled payloads through strict summaries, and expose only the closed
  `accepted | rejected | no_op` telemetry dimension.
- DSL: candidate language 5 declares typed rejection/no-op types and exhaustive
  accepted/rejected/no-op transition outcomes. Generated event-stream modules
  export a public `DomainCommandHandler` whose direct state/index classifier
  evaluates only the reason for Keiki's exact selected edge.
- Conformance: `keiro-dsl-conformance-domain-outcomes` compares independently
  owned typed witness reasons with the generated handler; its mutation script
  detects wrong reason/kind, missing clauses, replay-only annotations, silent
  emits, and silent writes.
- Scaling: fixed 8/32/128/512 check/generation rows enforce one classifier arm
  per silent edge, forbid lookup/search dispatch, and keep each fourfold size
  increase below the sixfold cap.
- Remaining: Plan 231's same-machine latency/allocation/maximum-residency
  evidence and Plan 232's committed outcome-generation baseline plus
  `bench-regression` wiring, both on a quiet host.

## Context

Keiro distinguishes hydration, ambiguity, encoding, storage, and retry failures, but a business
command with no matching edge becomes generic `CommandRejected`. A successful no-op is represented
only by `eventsAppended = 0`. HTTP/API layers and coordinators therefore cannot preserve a typed
reason such as `AlreadyCancelled`, `InsufficientCapacity`, or `DuplicateRequest` without re-running
domain logic or maintaining a parallel decision model.

## Requested Change

Add a type-safe command-decision/outcome surface that can carry application-defined rejection and
no-op details while retaining Keiro's infrastructure errors and exact appended-event metadata.
Integrate it with Keiki transducers, `runCommand*`, projections, routers/process managers, telemetry,
and generated DSL harness expectations. Do not turn arbitrary high-cardinality details into metric
labels.

## Acceptance

1. A command can return a typed accepted, rejected, or no-op domain result without encoding that
   result as an event or exception.
2. Optimistic retries preserve the final decision and never execute external callbacks for a
   rejected/no-op command.
3. Ambiguous definitions and infrastructure errors remain distinct from business rejection.
4. Generated conformance can assert a specific rejection/no-op reason.
5. Existing callers have a documented migration path and a compatibility adapter where sound.

## Requested Deliverables

- Public decision/result/error types and command-runner integration.
- Keiki and generated DSL boundary design.
- Retry, projection, coordination, telemetry, and compatibility tests.
- API guide and changelog/release note.
