-- | Starter @.keiro@ skeletons for the @new \<kind\>@ subcommand. Each skeleton
-- is a minimal, __valid__ spec for one node kind: it parses and passes
-- @validateSpec@ with zero error diagnostics (a test enumerates them), so the
-- skeletons double as living, guaranteed-valid notation examples.
--
-- Kinds whose validator couples to other nodes (a @publisher@ needs an @emit@; an
-- @emit@/@intake@ needs a @contract@; a @dispatch@ needs a @workqueue@; an
-- @operation@ references a @workflow@) ship the whole coupled mini-spec, so the
-- skeleton is self-contained and checks clean on its own.
module Keiro.Dsl.Skeleton
  ( skeletonFor,
    skeletonKinds,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Keiro.Dsl.LanguageVersion (currentStableLanguageVersion, languageVersionText)

-- | The valid @new \<kind\>@ arguments, in help/listing order.
skeletonKinds :: [Text]
skeletonKinds =
  [ "aggregate",
    "process",
    "router",
    "contract",
    "intake",
    "emit",
    "publisher",
    "workqueue",
    "dispatch",
    "workflow",
    "operation"
  ]

-- | The minimal valid spec text for a node kind, or a 'Left' error naming the
-- valid kinds when the argument is unrecognised.
skeletonFor :: Text -> Either Text Text
skeletonFor kind = case kind of
  "aggregate" -> Right (versioned aggregateSkeleton)
  "process" -> Right (versioned processSkeleton)
  "router" -> Right (versioned routerSkeleton)
  "contract" -> Right (versioned contractSkeleton)
  "intake" -> Right (versioned intakeSkeleton)
  "emit" -> Right (versioned emitSkeleton)
  "publisher" -> Right (versioned emitSkeleton)
  "workqueue" -> Right (versioned workqueueSkeleton)
  "dispatch" -> Right (versioned workqueueSkeleton)
  "workflow" -> Right (versioned workflowSkeleton)
  "operation" -> Right (versioned workflowSkeleton)
  other ->
    Left $
      "unknown kind '" <> other <> "'. Valid kinds: " <> T.intercalate ", " skeletonKinds
  where
    versioned source = "language keiro-dsl " <> languageVersionText currentStableLanguageVersion <> "\n" <> source

aggregateSkeleton :: Text
aggregateSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "id ThingId prefix=thing",
      "",
      "aggregate Thing",
      "  regs",
      "    thingId ThingId = placeholder",
      "  states Pending Done!",
      "",
      "  command DoThing { thingId attempt:Int }",
      "  event ThingCompleted { thingId attempt:Int }",
      "",
      "  Pending -- DoThing -->",
      "    emit ThingCompleted",
      "    goto Done",
      "",
      "  wire kind=ctorName fields=camelCase schemaVersion=1"
    ]

processSkeleton :: Text
processSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "id IncidentId prefix=inc",
      "",
      "process IncidentProcess",
      "  name \"incident-process\"",
      "  input IncidentInput { incidentId:IncidentId observedAt:Time }",
      "  correlate input.incidentId via idText",
      "  saga IncidentSaga category \"incidentSaga\"",
      "  target Incident",
      "  projections [ ]",
      "",
      "  on IncidentInput",
      "    advance NoteIncident { incidentId timerId=timer.id }",
      "    dispatch Incident@input.incidentId AcknowledgeIncident { incidentId }",
      "      on-appended AckOk ; on-duplicate AckOk ; on-failed Retry",
      "    schedule followUp",
      "",
      "  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)",
      "  rejected => halt",
      "  poison => halt",
      "",
      "  timer followUp",
      "    id uuidv5 \"incident-follow-up-timer:\" <> correlationId",
      "    fireAt input.observedAt + 5m",
      "    payload { kind=\"incident-follow-up\" incidentId }",
      "    fire dispatch IncidentSaga@correlationId MarkTimerFired { incidentId timerId }",
      "      fired-event-id uuidv5 \"incident-follow-up-fired:\" <> correlationId",
      "      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry",
      "    decode unknown-status => Cancelled",
      "    max-attempts 5 dead-letter \"incident follow-up exceeded ceiling\"",
      "",
      "aggregate IncidentSaga",
      "  regs",
      "  states Open",
      "  command NoteIncident { incidentId timerId }",
      "  command MarkTimerFired { incidentId timerId }",
      "  event IncidentNoted = fields(NoteIncident)",
      "  event TimerMarked = fields(MarkTimerFired)",
      "  Open -- NoteIncident --> emit IncidentNoted ; goto Open",
      "  Open -- MarkTimerFired --> emit TimerMarked ; goto Open",
      "",
      "aggregate Incident",
      "  regs",
      "  states Open",
      "  command AcknowledgeIncident { incidentId }",
      "  event IncidentAcknowledged = fields(AcknowledgeIncident)",
      "  Open -- AcknowledgeIncident --> emit IncidentAcknowledged ; goto Open"
    ]

routerSkeleton :: Text
routerSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "router PagingRouter",
      "  name \"paging-router\"",
      "  input IncidentRaised { incidentId service }",
      "  key input.incidentId via idText",
      "  resolve stable via hole row { responderId }",
      "  target Page",
      "  projections [ ]",
      "  dispatch-each SendPage { incidentId=input.incidentId responderId=resolved.responderId }",
      "    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry",
      "  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)",
      "  rejected => halt",
      "  poison => halt",
      "",
      "aggregate Page",
      "  regs",
      "  states Pending Delivered!",
      "",
      "  command SendPage { incidentId responderId }",
      "  event PageSent = fields(SendPage)",
      "",
      "  Pending -- SendPage --> emit PageSent ; goto Delivered"
    ]

contractSkeleton :: Text
contractSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "contract myContract {",
      "  schemaVersion 1",
      "  discriminator messageType",
      "",
      "  topic events \"my-service.events\"",
      "",
      "  event ThingHappened on events {",
      "    thingId: typeid \"thing\"",
      "    detail: text",
      "  }",
      "}"
    ]

intakeSkeleton :: Text
intakeSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "contract myContract {",
      "  schemaVersion 1",
      "  discriminator messageType",
      "  topic events \"my-service.events\"",
      "  event ThingHappened on events {",
      "    thingId: typeid \"thing\"",
      "  }",
      "}",
      "",
      "intake thingInbox {",
      "  contract myContract",
      "  topic events",
      "  accept ThingHappened",
      "",
      -- No `required`/`cross-check body` flags here: they are unenforced
      -- descriptive notation (IntakeBindFlagUnenforced), and the skeleton must
      -- pass the documented `--deny-warnings` CI gate as generated.
      "  bind messageId from header \"keiro-message-id\"",
      "",
      "  dedupe key messageId policy PreferIntegrationMessageId",
      "",
      "  decode {",
      "    envelope strict-required lenient-optional",
      "    body strict schemaVersion == 1",
      "  }",
      "",
      "  disposition {",
      "    processed => ackOk",
      "    duplicate => ackOk",
      "    inProgress => retry 5s",
      "    previouslyFailed => deadLetter \"previous inbox failure\"",
      "    decodeFailed => deadLetter",
      "    dedupeFailed => deadLetter",
      "    storeFailed => retry 5s",
      "  }",
      "}"
    ]

emitSkeleton :: Text
emitSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "contract myContract {",
      "  schemaVersion 1",
      "  discriminator messageType",
      "  topic events \"my-service.events\"",
      "  event ThingAccepted on events {",
      "    thingId: typeid \"thing\"",
      "  }",
      "}",
      "",
      "emit thingResponse {",
      "  contract myContract",
      "  topic events",
      "  source \"my-service\"",
      "  key thingId",
      "  map status {",
      "    \"accepted\" => ThingAccepted",
      "    _ => skip",
      "  }",
      "  messageId derive \"msg\" hole",
      "  idempotencyKey derive hole",
      "}",
      "",
      "publisher thingPublisher {",
      "  emit thingResponse",
      "  ordering PerKeyHeadOfLine",
      "  maxAttempts 10",
      "  backoff constant 2s",
      "  outboxId stable from messageId",
      "}"
    ]

workqueueSkeleton :: Text
workqueueSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "target accepted_transfer_needs_rows {",
      "  schema = \"my_service\"",
      "  table = \"accepted_transfer_needs\"",
      "  reset = clear",
      "}",
      "",
      "target transfer_decision_rows {",
      "  schema = \"my_service\"",
      "  table = \"transfer_decisions\"",
      "  reset = clear",
      "}",
      "",
      "rebuild-group transfer_dispatch {",
      "  targets = [ accepted_transfer_needs_rows transfer_decision_rows ]",
      "  order = [ accepted_transfer_needs_rows transfer_decision_rows ]",
      "}",
      "",
      "projection-owner accepted_transfer_needs_writer {",
      "  source = category \"acceptedTransferNeeds\"",
      "  delivery = subscription",
      "  group = transfer_dispatch",
      "  targets = [ accepted_transfer_needs_rows ]",
      "  order = 10",
      "  subscription = \"accepted-transfer-needs\"",
      "  dedup = \"accepted-transfer-needs-v1\"",
      "  checkpoint-on-missing = from-beginning",
      "  replay = explicit",
      "}",
      "",
      "projection-owner transfer_decisions_writer {",
      "  source = category \"transferDecisions\"",
      "  delivery = subscription",
      "  group = transfer_dispatch",
      "  targets = [ transfer_decision_rows ]",
      "  order = 20",
      "  subscription = \"transfer-decisions\"",
      "  dedup = \"transfer-decisions-v1\"",
      "  checkpoint-on-missing = from-beginning",
      "  replay = explicit",
      "}",
      "",
      "readmodel acceptedTransferNeeds {",
      "  columns {",
      "    reservation_id text required",
      "    hospital_id text required",
      "  }",
      "  version = 1",
      "  shape = \"fnv1a:5c91c3c0a3a2c01b\"",
      "  freshness = immediate",
      "  group = transfer_dispatch",
      "  targets = [ accepted_transfer_needs_rows ]",
      "}",
      "",
      "readmodel transferDecisions {",
      "  columns {",
      "    reservation_id text required",
      "  }",
      "  version = 1",
      "  shape = \"fnv1a:660844a62fd3d5b2\"",
      "  freshness = immediate",
      "  group = transfer_dispatch",
      "  targets = [ transfer_decision_rows ]",
      "}",
      "",
      "workqueue reservationWork {",
      "  queue logical = \"my_service.reservation_work\"",
      "  derive physical = \"my_service_reservation_work\"",
      "         dlq = \"my_service_reservation_work_dlq\"",
      "         table = \"pgmq.q_my_service_reservation_work\"",
      "",
      "  payload ReservationWorkItem {",
      "    reservationId -> \"reservation_id\" text required",
      "    hospitalId -> \"hospital_id\" text required",
      "  }",
      "",
      "  retry maxRetries = 3 delay = 5s dlq = on",
      "",
      "  disposition {",
      "    storeFailure -> retry 5s",
      "    commandRejected -> deadLetter",
      "    decodeFailure -> deadLetter",
      "    onCodecReject -> deadLetter",
      "  }",
      "}",
      "",
      "dispatch reservationWorkDispatch {",
      "  source readModel = acceptedTransferNeeds key = reservationId",
      "  fanout body = resolveTransferCandidates",
      "  dedup key = reservationId",
      "        seenIn readModel = transferDecisions field = reservation_id",
      "        seenIn queue = reservationWork field = reservation_id",
      "  enqueue to = reservationWork",
      "}"
    ]

workflowSkeleton :: Text
workflowSkeleton =
  T.unlines
    [ "context my-service",
      "",
      "workflow HospitalTransferReservation",
      "  name \"hospital-transfer-reservation\"",
      "  in ReservationWorkflowInput { reservationId:Id hospitalId:Id }",
      "  out ReservationWorkflowSummary",
      "  id from input.reservationId via idText",
      "  body",
      "    step create-transfer-hold -> ReservationHold",
      "    await reservation-confirmation -> ReservationConfirmation",
      "    step summarize-reservation -> ReservationWorkflowSummary",
      "",
      "operation SignalReservationConfirmation",
      "  signal reservation-confirmation of HospitalTransferReservation",
      "    key from reservationId via reservationWorkflowId",
      "    value ReservationConfirmation",
      "",
      "operation RunReservationWorkflow",
      "  run HospitalTransferReservation",
      "    input ReservationWorkflowInput",
      "    outcome -> ReservationWorkflowRun"
    ]
