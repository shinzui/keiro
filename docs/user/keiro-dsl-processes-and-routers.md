---
type: Reference
title: Keiro DSL Processes and Routers
description: Declare Keiro DSL process managers, reactions, timers, and custom or declarative routers.
docId: DOC-28
tags: [keiro, dsl, processes, routers, reference]
generated:
  by: anthropic-claude-code/claude-opus-5
  at: 2026-09-28T00:00:00Z
---

# Keiro DSL Processes and Routers

This page covers the coordination nodes: process managers with timers and
reactions, and stateless routers with custom or declarative selection. It is part of the [Keiro DSL Reference](keiro-dsl-reference.md), which
introduces the language, its versions, and source file structure.

## Processes and timers

Language 5 supports the single-input, single-timer process form. The
unpublished Language 6 candidate adds a reaction form with multiple typed
inputs, ordered guarded arms, optional advancement, timer-free processes, and
multiple independently named timers. The following process is entirely
generated except for decoding a `RecordedEvent` into `IncidentReactionInput`:

```keiro
language keiro-dsl 6
context incident-response

process IncidentReaction
  name "incident-reaction"
  reactions version 1
  input IncidentReported { incidentId:IncidentId severity:Severity }
  input IncidentNoted { incidentId:IncidentId }
  correlate input.incidentId via idText
  saga IncidentSaga category "incidentSaga"
  target Incident
  projections [ ]

  on IncidentReported
    when input.severity == Severity.Sev1
      advance RecordCritical { incidentId }
      dispatch Incident@input.incidentId EscalateIncident { incidentId }
        on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
    otherwise
      advance RecordRoutine { incidentId }

  on IncidentNoted
    no-action

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, targetStreamName, occurrence)
  rejected => halt
  poison => halt
```

Each input declaration has exactly one `on` block. Arms are tested top to bottom;
an `on` block containing `when` must end in `otherwise`, while an unconditional
arm stands alone. Guards may read only fields of the selected input and must be
Boolean. Saga state is deliberately unavailable: the saga command handler is
the checked, hydrated, optimistic-retry authority. `no-action` performs no saga
read or append and has no durable receipt.

An `advance` may place follow-ups directly after the command, making them
unconditional, or under `accepted`, making them eligible only after a non-empty
accepted saga append or recovery of its exact first-event witness. An
`accepted` block requires `silent no-action` beside it because rejection, no-op,
and eventless acceptance leave no receipt. Unconditional effects may repeat
after a silent result. Selected unconditional effects precede accepted-only
effects; timer statements execute before target dispatch attempts, but target
commands still commit in separate transactions.

Timers are optional. When present, declare one process-wide worker policy and
one block per timer:

```keiro
  on IncidentReported
    advance RecordIncident { incidentId }
    schedule escalation fireAt input.raisedAt + 5m { incidentId detail }
    schedule reminder once fireAt input.raisedAt + 60m { incidentId }

  on ResponderAcked
    cancel reminder

  timers max-attempts 5 dead-letter "incident timer exceeded ceiling"

  timer escalation
    id uuidv5 "incident-escalation-timer:" <> correlationId
    payload { kind="escalation" incidentId:IncidentId detail:Text }
    fire dispatch Incident@correlationId EscalateIncident { incidentId }
      fired-event-id uuidv5 "incident-escalation-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
```

`schedule` defaults to rearm; `schedule ... once` is insert-only. `cancel`
uses the named timer's deterministic id. The timer id and fired-event id are
UUIDv5 over the UTF-8 bytes of separately
length-prefixed prefix and correlation fields. This preserves non-ASCII text
without the code-point truncation that could alias distinct correlations.
A timer's constant and typed payload
fields must be supplied exactly once by every schedule. Deadlines must derive
from an injected `:Time` input field. Timer and fired-event prefixes must be
unique within the process, and each id ends in `correlationId`. Cancellation
does not create a tombstone, revive terminal rows, or revoke a callback that
already claimed the timer.

The reaction dispatch identity is target-keyed:
`(name, correlationId, sourceEventId, targetStreamName, occurrence)`, where
`occurrence` counts commands to the same physical target in declared order.
The generated reaction version and SHA-256 semantic fingerprint are review and
coordination metadata; neither changes runtime ids. The generated module owns
the input ADT, pure reaction, `ReactiveProcessManager`, worker wrapper, typed
timer payloads/builders, and firing dispatcher. The sole create-once process
hole is `decode<Process>Input :: RecordedEvent -> Maybe <Process>Input`.

Reaction validation adds these source-local errors:

- `ProcessReactionUnknownInput`, `ProcessInputDuplicateDeclaration`,
  `ProcessReactionInputUnhandled`, and `ProcessReactionDuplicateInput` enforce
  total one-to-one input/reaction ownership.
- `ProcessReactionGuardNotBoolean`, `ProcessStateAccessUnsupported`,
  `ProcessReactionOtherwiseMissing`, and
  `ProcessReactionOtherwiseUnreachable` enforce deterministic ordered guards.
- `ProcessTimerDuplicateName`, `ProcessTimerPrefixCollision`,
  `ProcessScheduleUnknownTimer`, `ProcessCancelUnknownTimer`,
  `ProcessSchedulePayloadIncomplete`, `ProcessTimerPolicyMissing`, and
  `ProcessTimerPolicyUnused` enforce timer identity, payload, and worker policy.
- `ProcessAcceptedArmRequiresEvent`, `ProcessSilentArmMissing`, and
  `ProcessAcceptedArmUnverified` enforce durable acceptance ownership.
- `ProcessBindingTypeMismatch` rejects command, dispatch, and timer mappings
  whose source and destination types differ.

Reaction evolution adds `ProcessReactionAdded`, `ProcessReactionRemoved`,
`ProcessReactionFanOutChanged`, `ProcessReactionGuardChanged`,
`ProcessReactionArmsReordered`, `ProcessTimerAdded`, `ProcessTimerRemoved`,
`ProcessTimerIdentityChanged`, `ProcessTimerCeilingChanged`,
`ProcessReactionVersionDecreased`,
`ProcessReactionFingerprintChangedWithoutVersionBump`,
`ProcessReactionFingerprintChangedWithVersionBump`, and
`ProcessDispatchIdentityModelChanged`. Timer payload changes continue to use
`ProcessTimerPayloadChanged`. A semantic fingerprint change must increase
`reactions version`, but the bump records intent only: drain/replay and timer
compatibility obligations remain.

## Routers

A router resolves zero or more target rows for an input and dispatches one
command per row without keeping its own event-sourced state.

```keiro
router HospitalTransferRouter
  name "hospital-transfer-router"
  input AcceptedTransferNeed { transferNeedId region }
  key input.transferNeedId via idText
  resolve stable via read-model hospital_load row { hospitalId }
  target Hospital
  projections [ ]
  dispatch-each RouteAcceptedTransferNeed {
    transferNeedId=input.transferNeedId
    hospitalId=resolved.hospitalId
  }
    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)
  rejected => deadLetter
  poison => halt
```

`name` follows the stable identity rules described for processes. `key` must
name an input field. A resolver is either `via read-model Name` for a declared
read model or `via hole` for another typed effectful implementation. Every
`row` field on a read-model resolver must name a column of
that read model; only verified row fields become available under `resolved.*`.

The mandatory `resolve stable` phrase acknowledges retry semantics: later
attempts deduplicate targets already dispatched, but a resolver whose result
changes can accumulate the union of targets seen across attempts.

A router also admits a checked, bounded selection:

```keiro
resolve declarative {
  identity = "hospital-transfer-selection"
  version = 1
  query = read-model hospital_load with input
  where = row.region == input.region && row.availableBeds > 0
  recipient = row.hospitalId
  order = target-stream
  dedupe = target-stream
  max-recipients = 64
  empty => ack
  failure => retry
  redelivery = stable-union
  partial = retain-successes
}
```

The query input must be mapped structural and the query result must be a list of
mapped structural rows. Check resolves and types the key, predicate, recipient,
and every dispatch field; requires a positive recipient limit; and admits only
the normalization and redelivery policies shown above. The application still
owns the read-model SQL body. Generated code filters and maps its typed result,
sorts commands by physical target stream, collapses exact duplicates, rejects
unequal commands for one stream, and applies the cap after deduplication before
performing any write.

Candidate Language 6 also permits declared nominal leaves in those required
structural paths. A selection such as `recipient = row.templateId` retains the
ID's domain type and records `SelectionNominal` in the checked selection
identity. Predicate equality is allowed only between values of the same
nominal declaration. Optional and collection paths remain non-traversable.

`empty` accepts `ack`, `retry`, `deadLetter`, or `halt`. `failure` accepts
`retry`, `deadLetter`, or `halt`; failures include query/evaluation errors,
target conflicts, and cap overflow. Dispatch itself remains one transaction per
target and retains earlier successes. See
[Routers And Effectful Fan-Out](../guides/routers-and-effectful-fan-out.md#declarative-selection-in-language-5)
for the complete contract and evolution workflow.

Dispatch binding values may be quoted literals, `input.*`, or `resolved.*`.
Bare bindings copy an input field of the same name. Target aggregate, command,
command fields, read model, and projection references are checked. The
dispatch-ID expression is fixed runtime policy and must be written exactly as
shown.
