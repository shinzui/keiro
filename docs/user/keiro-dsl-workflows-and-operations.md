---
type: Reference
title: Keiro DSL Workflows and Operations
description: Declare Keiro DSL durable workflows and command, query, signal, and workflow-run operations.
docId: DOC-31
tags: [keiro, dsl, workflows, operations, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Workflows and Operations

This page covers durable workflows and the named operation entry points. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Workflows

```keiro
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"
  in ReservationWorkflowInput {
    reservationId:Id
    coolingOffDelay:Duration
  }
  out ReservationWorkflowSummary
  id from input.reservationId via idText
  body
    step create-transfer-hold -> ReservationHold
    patch fraud-check-v2 {
      step fraud-check -> FraudCheckResult
    }
    await reservation-confirmation -> ReservationConfirmation
    sleep cooling-off after coolingOffDelay
    child ship-order id input via shipChildId -> Text
    continueAsNew RolloverSeed
```

`name` is the stable workflow identity and follows the same rules and
cross-family uniqueness constraint as process and router names. `in` declares
an input type and optional field inventory; `out` declares the output type.
`id from input via fn` derives from the whole input, while
`id from input.field via fn` requires that field to exist.

The body is ordered, but replay matches journal records by label. Labels across
steps, waits, sleeps, children, and nested patches must be unique. A sleep's
delay names an input field, so time is injected rather than sampled. Child IDs
come from the named hand-owned derivation function.

`patch id { ... }` journals a durable branch decision for an in-flight
evolution. Patch IDs are unique across nested blocks and cannot contain `:`.
Do not reuse an old ID. Use a patch for a coordinated multi-step change; a
single changed step can usually receive a new label.

`continueAsNew SeedType` rotates an unbounded workflow to a new journal
generation. It may appear only as the final top-level body item, never inside a
patch.

Workflow behavior remains hand-owned. The scaffold generates durable facts and
runtime wiring, not the workflow's business body.

## Operations

Operations name application entry points. Four shapes are supported. Operation
declarations are validated and diff-classified but produce no generated module
today; the command/query/signal/run implementation boundary is hand-owned.

### Command operation

```keiro
operation ConfirmReservation
  command on Reservation
    stream from reservationId via reservationStream
    project [ transferDecision ]
```

The aggregate, stream field, and projections must resolve. `via` names the
hand-owned stream derivation.

### Query operation

```keiro
operation QueryTransferDecision
  query transferDecision
    input TransferReservationId
    result Maybe TransferDecision
    consistency Strong
```

The read model must resolve. Consistency is `Strong`, `Eventual`, or
`PositionWait`; omitted consistency defaults to `Strong`. The result is kept as
a Haskell type phrase and can contain multiple identifiers.

### Signal operation

```keiro
operation SignalReservationConfirmation
  signal reservation-confirmation of HospitalTransferReservation
    key from reservationId via reservationWorkflowId
    value ReservationConfirmation
```

The workflow and await label must resolve, and `value` must equal the await's
result type. A mismatch would create a different awakeable identity or payload
and leave the workflow waiting.

### Run operation

```keiro
operation RunReservationWorkflow
  run HospitalTransferReservation
    input ReservationWorkflowInput
    outcome -> ReservationWorkflowRun
```

The workflow must resolve. The input and outcome names define the hand-owned
application boundary.
