---
title: "Typed domain command outcomes"
type: Capability
description: "Return accepted event batches, typed business rejections, and typed successful no-ops from the command path without turning expected domain decisions into persistence errors."
generated:
  by: openai/codex
  at: "2026-08-15T00:00:00Z"
capabilityId: CAP-18
provider: mori://shinzui/keiro
status: shipped
stability: experimental
since: "0.12.0.0"
packages:
  - keiro
  - keiro-dsl
interface:
  - Keiro.Command
requires:
  - CAP-3
evidence:
  - kind: test
    resource: keiro/test/Main.hs
    proves: "The 'typed domain command outcomes' block proves exact accepted batches, typed rejected/no-op decisions, retry recomputation, SQL/projection/catalog short-circuiting, coordinator propagation, and bounded telemetry labels."
  - kind: test
    resource: jitsurei/test/Main.hs
    proves: "The order example exhaustively handles accepted, rejected, and no-op results and proves that only accepted decisions append events and invoke inline projections."
  - kind: conformance
    resource: keiro-dsl/test/conformance-domain-outcomes/Main.hs
    proves: "A generated Language-5 domain-outcome handler and its independent behavior witnesses compile and agree on accepted, rejected, and no-op transitions."
  - kind: guide
    resource: docs/user/command-cycle.md
    proves: "How to define a DomainCommandHandler, call each outcome-aware runner, preserve transactional behavior, and handle results exhaustively."
---

# Typed domain command outcomes

`DomainCommandHandler` adds application meaning to a successfully selected
command edge in the [transactional command cycle](transactional-command-cycle.md).
An accepted edge returns the exact non-empty event batch that was
encoded and appended. An explicitly selected, eventless, write-free self-loop
can instead return a typed business rejection or typed successful no-op. A
missing edge and an ambiguous edge remain framework `CommandError` values; the
domain classifier cannot disguise them.

The classifier receives the exact edge selected by the replay-safe transducer
plus the pre-command state, registers, and command. It does not run guards again.
All ordinary retry and atomicity guarantees remain in force: a conflict
rehydrates and recomputes the decision, accepted results invoke the transactional
SQL/projection path, and silent decisions skip those callbacks. Parallel
projection-catalog, process-manager, and router APIs preserve the typed result.

Language 5 can declare rejection and no-op result types and annotate every live
transition. Scaffolding emits the `DomainCommandHandler`; conformance witnesses
check each generated classification independently. Telemetry records only the
bounded `accepted`, `rejected`, or `no_op` class, never an application reason as
a metric label.

## Shape

```haskell
case result of
  Right DomainCommandOutcome { decision = DomainAccepted events } -> ...
  Right DomainCommandOutcome { decision = DomainRejected reason } -> ...
  Right DomainCommandOutcome { decision = DomainNoOp explanation } -> ...
  Left commandError -> ...
```

## Limits

- Rejection and no-op reasons exist only for explicitly selected silent edges.
  They are not a fallback for a command with no matching edge.
- A silent domain decision cannot write registers, change control state, emit an
  event, or run the transactional after-append callback. Model any durable
  change as an accepted event.
- Domain outcomes describe forward command behavior and are not persisted in
  event history. Changing their types or meanings is an application API change,
  even when replay compatibility is unchanged.
