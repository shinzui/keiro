---
type: Improvement Request
title: Expose reason-bearing dead timer reads
description: >-
  Expose recorded dead-letter reasons and filtered dead timer listings through the public
  timer API so consumers can inspect deferred work without querying Keiro-owned tables.
timestamp: 2026-09-08T14:25:26Z
requestId: IR-35
status: completed
origin: mori://shinzui/kioku
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-09-08T14:25:26Z"
    document_timestamp: "2026-09-08T14:25:26Z"
    scope: completion-evidence
    outcome: approved
    provider: openai
    model: unspecified
    effort: unspecified
    context: >-
      Consumer implementation-author review of released APIs, Hackage metadata,
      upstream release tags, Kioku recovery/CLI/migration tests, and corrected
      Rei host acceptance. Source validation is distinguished from deployment.
---

# Improvement Request: Expose Reason-Bearing Dead Timer Reads

## Status

Completed in released `mori://shinzui/keiro/packages/keiro` 0.16.0.0. Hackage lists the
release; upstream `keiro-0.16.0.0` resolves to
`2da45585b901271d4ac19af4acf3de790c394540`. The consumer acceptance is recorded in
`mori://shinzui/kioku/plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy`.


## Context

Kioku parks background AI work with `deadLetterTimer` when its host permits interactive
execution but the background worker has no interactive session. A stable reason identifies
this deferred work, which must remain distinguishable from malformed payloads, authorization
refusals, and ordinary exhausted retries. Repeated worker polls leave it parked.

In `keiro/src/Keiro/Timer/Schema.hs` at commit
`c3c935c65d641c91867ab2d779ffe9559ba9abfc`, `deadLetterTimer` stores `last_error`, but
`TimerRow` and `lookupTimer` omit it. `findStuckTimers` selects only `Firing` rows; no public
operation lists dead timers. Plan 41 recorded the same gap against released Keiro 0.15.0.0,
verified against Hackage metadata and upstream tags on 2026-09-08. This request chooses no
new dependency bound; implementation must recheck the released baseline before adoption.

[IR-29](expose-process-manager-inspection-reads.md) requests pending-timer inspection for a
runtime UI. This request adds the specific dead-state and stored-reason contract needed for
consumer recovery; it does not require HTTP endpoints.

## Requested Change

1. Provide a supported public read of a timer's stored `last_error`, using an extended row
   or a dedicated inspection type. Preserve the distinction between a missing reason and an
   empty reason. Include timer ID, process-manager name, correlation ID, original payload,
   state, and attempt count so consumers can validate ownership and explain the work.
2. Provide read-only dead-timer listing with process-manager and reason filters. Document
   exact versus prefix matching; support identifying a stable reason category while keeping
   the full stored reason available for the companion compare-and-set operation. Bound result
   sizes and give deterministic ordering/pagination semantics.
3. Keep these operations in the public `Keiro.Timer` surface. Consumers must not need
   private SQL, internal decoders, or an application-specific Keiro schema extension.
4. Document that the caller owns application authorization. Kioku filters decoded memory
   spaces against fresh access permissions before displaying entries; Keiro must not invent
   memory-space identity or authorize AI execution.

## Acceptance

1. Public API tests round-trip absent and populated reasons and all original timer metadata.
2. Mixed fixtures include ordinary dead letters, deferred timers from multiple process
   managers, and scheduled/firing/fired/cancelled rows. Filters return only the intended dead
   rows; bounded pages have deterministic ordering and documented behavior under changes.
3. Reads do not claim timers, increment attempts, clear reasons, or change timestamps/state.
4. Existing lookup callers remain supported or receive explicit source-compatibility guidance.
5. A downstream Kioku fixture can identify and render deferred work through public APIs,
   while omitting unauthorized spaces. No direct reads of Keiro-owned tables are needed.

## Requested Deliverables

Public types and operations, PostgreSQL integration tests, API/compatibility documentation,
and a tagged Hackage release of `mori://shinzui/keiro/packages/keiro` that consumers can adopt.
If a migration is necessary, add a new migration rather than changing an applied one. Keep
this request proposed until implementation and release evidence are recorded.

## Implementation evidence

[ExecPlan 270](../plans/270-expose-reason-bearing-dead-timer-inspection-and-bounded-reads.md)
adds public `TimerInspection`, `lookupTimerInspection`, and bounded
`findDeadTimers` with literal filters and UUID continuation, preserving the old
row and worker interfaces without a migration. On 2026-09-08,
`nix develop -c cabal test keiro-test --test-options='--match Keiro.Timer' --test-show-details=direct`
passed 19 examples with zero failures. The fixtures include full reason
preservation, legacy NULL, mixed lifecycle/owner filtering, bounded pages under
changes, unchanged persisted columns, and application permission filtering past
empty pages with revocation. The consumer-style fixture is local simulation,
not evidence of downstream adoption.

Status remains proposed: the shared tagged Hackage release is coordinated with
IR-36, which is still pending. Actual downstream acceptance against a released
bound remains required. Hackage and upstream tags were rechecked on 2026-09-08;
0.15.0.0 remains the current normal release, at tagged commit
`de574cdcb0add3fefbb0fdd96d820258d15f8997`.

## Completion evidence (2026-09-08)

Public inspection and bounded reason-filtered listing shipped through `Keiro.Timer` in 0.16.0.0.
Kioku commit `6862915` in `mori://shinzui/kioku` adopts the public API without application
SQL against Keiro's timer table. Its final 20 timer tests cover authorized paginated listing,
refused/disabled/unavailable preflights without attempt consumption, concurrent foreground
interactive execution with one winner, cancellation parking, expired-claim recovery, and
stale-token completion refusal. Its 58 CLI tests include a subprocess listing/refusal/resume
flow; all 24 composed-migration tests pass with Keiro migration 0032.

The corrected reporting-host fixture in commit `8446ca18` of `mori://shinzui/rei` passed in
the 40-test durable selection with local Kioku source and released Keiro dependencies. It
asserts a real deferred reason, authorized listing, and foreground completion of the original
timer once. This is downstream source acceptance; the forthcoming Kioku package release and
live-host deployment remain consumer release work, not missing Keiro API functionality.
