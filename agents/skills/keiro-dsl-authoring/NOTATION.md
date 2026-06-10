# keiro-dsl notation reference

A `.keiro` file is `context <name>` followed by top-level declarations and nodes. `#` begins a
line comment; whitespace/newlines are insignificant (structure comes from keywords). Every
node family below is parsed, validated, and round-tripped by the toolchain.

## Shared declarations

```text
context hospital-capacity

id   TransferReservationId  prefix=rsv          # an id newtype over Text
enum DivertStatus { Open=open TotalDivert=total-divert }   # Ctor=wire-spelling
rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false
```

## aggregate (EP-1) + evolution (EP-2)

```text
aggregate Reservation
  regs
    reservationState ReservationVertex = Unrequested      # name Type = initial
  states Unrequested Held Confirmed Expired!              # trailing ! = terminal (no outgoing)

  command RequestTransferReservation { reservationId hospitalId commandId divertStatus lifeCriticalOverride:Bool }
  event   TransferReservationCreated = fields(RequestTransferReservation)
  event   TransferReservationConfirmed v2 { reservationId hospitalId triageNote:Text }
    upcast from v1 = HOLE                                 # EP-2: vN>1 needs a contiguous upcaster hole
  deprecated event LegacyOpened { reservationId }         # removed from write path, still decodable

  Unrequested -- RequestTransferReservation -->
    guard divertStatus != TotalDivert || lifeCriticalOverride   # a typed Expr, scope-checked
    write reservationState := Held
    emit  TransferReservationCreated
    goto  Held

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transfer_decisions consistency=Strong key=reservationId
    status-map { Created=>held Confirmed=>confirmed }    # event-suffix => status; must be total
```

Holes (you fill): the transducer body (guards/writes/emits via keiki operators), the
projection SQL `apply`, any `upcast<Event>V<n>` upcaster body.

## process + timer (EP-3)

```text
process HospitalSurge
  name "hospital-surge"
  input SurgeInput { hospitalId availableIcuBeds:Int observedAt:Time }
  correlate input.hospitalId via idText
  saga Surge stream="hospital-surge-" <> correlationId
  target Hospital
  projections [ hospitalReadiness ]
  on SurgeInput
    advance NoteSurgeThreshold { hospitalId timerId=timer.id }
    dispatch Hospital@input.hospitalId ActivateSurge { hospitalId }
      on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
    schedule surgeFollowUp
  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)   # runtime-owned; fixed
  timer surgeFollowUp
    id uuidv5 "hospital-surge-timer:" <> correlationId
    fireAt input.observedAt + 5m                          # TIME INJECTED, not sampled
    payload { kind="hospital-surge-follow-up" hospitalId }
    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }
      fired-event-id uuidv5 "hospital-surge-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-error Retry ; not-mine Retry   # on-reject Fired = benign inversion
    decode unknown-status => Cancelled
    max-attempts 5 dead-letter "surge timer exceeded ceiling"   # forces the dangerous default OFF
```

Checked: fireAt must reference a `:Time` input field; no user dispatch-id; saga/target/fire
targets resolve. Holes: the `handle` body, the deadline window, the fire command, the SQL.

## contract / intake / emit / publisher (EP-4)

```text
contract emergency {
  schemaVersion 1
  discriminator messageType
  topic incidentEvents "emergency.incident.events"
  event IncidentTransferNeedDeclared on incidentEvents { incidentId: typeid "inc"; region: text; redCount: int }
}

intake incidentInbox {
  contract emergency
  topic incidentEvents
  accept IncidentTransferNeedDeclared
  bind messageId from header "keiro-message-id" required cross-check body
  bind key from kafka-key
  dedupe key messageId policy PreferIntegrationMessageId
  decode { envelope strict-required lenient-optional ; body strict schemaVersion == 1 }
  disposition {                                            # MANDATORY + COMPLETE (7 outcomes)
    processed => ackOk
    duplicate => ackOk                                     # inversion 1: replay is SUCCESS
    inProgress => retry 5s
    previouslyFailed => deadLetter "prior failure"          # inversion 2: NOT retry
    decodeFailed => deadLetter                             # inversion 3: poison, NOT unbounded retry
    dedupeFailed => deadLetter
    storeFailed => retry 5s
  }
}

emit reservationResponse {
  contract emergency ; topic hospitalEvents ; source "hospital-capacity" ; key incidentId
  map status { "confirmed" => TransferReservationAccepted  _ => skip }   # `_ => skip` is MANDATORY
  messageId derive "msg" hole ; idempotencyKey derive hole
}

publisher hospitalPublisher {
  emit reservationResponse ; ordering PerKeyHeadOfLine ; maxAttempts 10
  backoff constant 2s ; outboxId stable from messageId
}
```

Checked: complete disposition table + the three inversions; `_ => skip` present; contract/
topic/event coupling resolves; publisher→emit resolves.

## workqueue / dispatch (EP-5)

```text
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"   # captured fixture; validator re-derives + checks drift
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"
  payload ReservationWorkItem { reservationId -> "reservation_id" text required }
  retry maxRetries = 3 delay = 5s dlq = on                 # dlq=on needs maxRetries>=1
  disposition {
    storeFailure -> retry 5s                               # transient: MUST retry
    decodeFailure -> deadLetter                            # poison: MUST dead-letter
    commandRejected -> deadLetter
    onCodecReject -> deadLetter
  }
}

dispatch reservation_work_dispatch {
  source readModel = accepted_transfer_needs key = reservationId
  fanout body = resolveTransferCandidates                  # effectful 1->N — HOLE
  dedup key = reservationId
        seenIn readModel = transfer_decisions field = reservation_id
        seenIn queue = reservation_work field = reservation_id   # raw-SQL — HOLE
  enqueue to = reservation_work
}
```

## workflow / operation (EP-6)

```text
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"
  in ReservationWorkflowInput { reservationId:Id hospitalId:Id }
  out ReservationWorkflowSummary
  id from input.reservationId via idText
  body                                                     # ORDERED; replay matches on label
    step  create-transfer-hold      -> ReservationHold
    await reservation-confirmation  -> ReservationConfirmation
    sleep cooling-off after coolingOffDelay               # TIME INJECTED
    child ship-order id input via shipChildId -> Text     # child id MUST differ from parent's

operation SignalReservationConfirmation
  signal reservation-confirmation of HospitalTransferReservation   # MUST match an await label
    key from reservationId via reservationWorkflowId
    value ReservationConfirmation
operation RunReservationWorkflow
  run HospitalTransferReservation
    input ReservationWorkflowInput
    outcome -> ReservationWorkflowRun
```

Operation shapes: `command on <Agg> …`, `query <ReadModel> …`, `signal <label> of <Wf> …`,
`run <Wf> …`. Checked: every `signal <label> of <wf>` matches an `await <label>` of that
workflow (else the awakeable id never matches and the workflow waits forever).
