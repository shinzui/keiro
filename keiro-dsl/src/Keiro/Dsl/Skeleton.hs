{- | Starter @.keiro@ skeletons for the @new \<kind\>@ subcommand. Each skeleton
is a minimal, __valid__ spec for one node kind: it parses and passes
@validateSpec@ with zero error diagnostics (a test enumerates them), so the
skeletons double as living, guaranteed-valid notation examples.

Kinds whose validator couples to other nodes (a @publisher@ needs an @emit@; an
@emit@/@intake@ needs a @contract@; a @dispatch@ needs a @workqueue@; an
@operation@ references a @workflow@) ship the whole coupled mini-spec, so the
skeleton is self-contained and checks clean on its own.
-}
module Keiro.Dsl.Skeleton (
    skeletonFor,
    skeletonKinds,
) where

import Data.Text (Text)
import Data.Text qualified as T

-- | The valid @new \<kind\>@ arguments, in help/listing order.
skeletonKinds :: [Text]
skeletonKinds =
    [ "aggregate"
    , "process"
    , "router"
    , "contract"
    , "intake"
    , "emit"
    , "publisher"
    , "workqueue"
    , "dispatch"
    , "workflow"
    , "operation"
    ]

{- | The minimal valid spec text for a node kind, or a 'Left' error naming the
valid kinds when the argument is unrecognised.
-}
skeletonFor :: Text -> Either Text Text
skeletonFor kind = case kind of
    "aggregate" -> Right aggregateSkeleton
    "process" -> Right processSkeleton
    "router" -> Right routerSkeleton
    "contract" -> Right contractSkeleton
    "intake" -> Right intakeSkeleton
    "emit" -> Right emitSkeleton
    "publisher" -> Right emitSkeleton
    "workqueue" -> Right workqueueSkeleton
    "dispatch" -> Right workqueueSkeleton
    "workflow" -> Right workflowSkeleton
    "operation" -> Right workflowSkeleton
    other ->
        Left $
            "unknown kind '" <> other <> "'. Valid kinds: " <> T.intercalate ", " skeletonKinds

aggregateSkeleton :: Text
aggregateSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "id ThingId prefix=thing"
        , ""
        , "aggregate Thing"
        , "  regs"
        , "    thingId ThingId = placeholder"
        , "    state ThingVertex = Pending"
        , "  states Pending Done!"
        , ""
        , "  command DoThing { thingId attempt:Int }"
        , "  event ThingCompleted { thingId attempt:Int }"
        , ""
        , "  Pending -- DoThing -->"
        , "    write state := Done"
        , "    emit ThingCompleted"
        , "    goto Done"
        , ""
        , "  wire kind=ctorName fields=camelCase schemaVersion=1"
        ]

processSkeleton :: Text
processSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "id  HospitalId  prefix=hosp"
        , "id  CommandId   prefix=cmd"
        , ""
        , "process HospitalSurge"
        , "  name \"hospital-surge\""
        , "  input SurgeInput { hospitalId availableIcuBeds:Int redDemand:Int observedAt:Time }"
        , "  correlate input.hospitalId via idText"
        , "  saga Surge category \"hospitalSurge\""
        , "  target Hospital"
        , "  projections [ ]"
        , ""
        , "  on SurgeInput"
        , "    advance NoteSurgeThreshold { hospitalId availableIcuBeds redDemand timerId=timer.id }"
        , "    dispatch Hospital@input.hospitalId ActivateSurge { hospitalId }"
        , "      on-appended AckOk ; on-duplicate AckOk ; on-failed Retry"
        , "    schedule surgeFollowUp"
        , ""
        , "  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)"
        , "  rejected => halt"
        , "  poison => halt"
        , ""
        , "  timer surgeFollowUp"
        , "    id uuidv5 \"hospital-surge-timer:\" <> correlationId"
        , "    fireAt input.observedAt + 5m"
        , "    payload { kind=\"hospital-surge-follow-up\" hospitalId }"
        , "    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }"
        , "      fired-event-id uuidv5 \"hospital-surge-fired:\" <> correlationId"
        , "      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry"
        , "    decode unknown-status => Cancelled"
        , "    max-attempts 5 dead-letter \"surge timer exceeded ceiling\""
        , ""
        , "aggregate Surge"
        , "  regs"
        , "  states Idle Fired!"
        , ""
        , "  command NoteSurgeThreshold { hospitalId availableIcuBeds:Int redDemand:Int timerId }"
        , "  command MarkSurgeTimerFired { hospitalId timerId }"
        , "  event SurgeThresholdNoted = fields(NoteSurgeThreshold)"
        , "  event SurgeTimerMarked = fields(MarkSurgeTimerFired)"
        , "  Idle -- NoteSurgeThreshold --> emit SurgeThresholdNoted ; goto Idle"
        , "  Idle -- MarkSurgeTimerFired --> emit SurgeTimerMarked ; goto Fired"
        , ""
        , "aggregate Hospital"
        , "  regs"
        , "  states Operational Surging!"
        , ""
        , "  command ActivateSurge { hospitalId }"
        , "  event SurgeActivated = fields(ActivateSurge)"
        , "  Operational -- ActivateSurge --> emit SurgeActivated ; goto Surging"
        ]

routerSkeleton :: Text
routerSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "router PagingRouter"
        , "  name \"paging-router\""
        , "  input IncidentRaised { incidentId service }"
        , "  key input.incidentId via idText"
        , "  resolve stable via hole row { responderId }"
        , "  target Page"
        , "  projections [ ]"
        , "  dispatch-each SendPage { incidentId=input.incidentId responderId=resolved.responderId }"
        , "    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry"
        , "  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)"
        , "  rejected => halt"
        , "  poison => halt"
        , ""
        , "aggregate Page"
        , "  regs"
        , "  states Pending Delivered!"
        , ""
        , "  command SendPage { incidentId responderId }"
        , "  event PageSent = fields(SendPage)"
        , ""
        , "  Pending -- SendPage --> emit PageSent ; goto Delivered"
        ]

contractSkeleton :: Text
contractSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "contract myContract {"
        , "  schemaVersion 1"
        , "  discriminator messageType"
        , ""
        , "  topic events \"my-service.events\""
        , ""
        , "  event ThingHappened on events {"
        , "    thingId: typeid \"thing\""
        , "    detail: text"
        , "  }"
        , "}"
        ]

intakeSkeleton :: Text
intakeSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "contract myContract {"
        , "  schemaVersion 1"
        , "  discriminator messageType"
        , "  topic events \"my-service.events\""
        , "  event ThingHappened on events {"
        , "    thingId: typeid \"thing\""
        , "  }"
        , "}"
        , ""
        , "intake thingInbox {"
        , "  contract myContract"
        , "  topic events"
        , "  accept ThingHappened"
        , ""
        , "  bind messageId from header \"keiro-message-id\" required cross-check body"
        , ""
        , "  dedupe key messageId policy PreferIntegrationMessageId"
        , ""
        , "  decode {"
        , "    envelope strict-required lenient-optional"
        , "    body strict schemaVersion == 1"
        , "  }"
        , ""
        , "  disposition {"
        , "    processed => ackOk"
        , "    duplicate => ackOk"
        , "    inProgress => retry 5s"
        , "    previouslyFailed => deadLetter \"previous inbox failure\""
        , "    decodeFailed => deadLetter"
        , "    dedupeFailed => deadLetter"
        , "    storeFailed => retry 5s"
        , "  }"
        , "}"
        ]

emitSkeleton :: Text
emitSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "contract myContract {"
        , "  schemaVersion 1"
        , "  discriminator messageType"
        , "  topic events \"my-service.events\""
        , "  event ThingAccepted on events {"
        , "    thingId: typeid \"thing\""
        , "  }"
        , "}"
        , ""
        , "emit thingResponse {"
        , "  contract myContract"
        , "  topic events"
        , "  source \"my-service\""
        , "  key thingId"
        , "  map status {"
        , "    \"accepted\" => ThingAccepted"
        , "    _ => skip"
        , "  }"
        , "  messageId derive \"msg\" hole"
        , "  idempotencyKey derive hole"
        , "}"
        , ""
        , "publisher thingPublisher {"
        , "  emit thingResponse"
        , "  ordering PerKeyHeadOfLine"
        , "  maxAttempts 10"
        , "  backoff constant 2s"
        , "  outboxId stable from messageId"
        , "}"
        ]

workqueueSkeleton :: Text
workqueueSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "readmodel accepted_transfer_needs {"
        , "  table = \"accepted_transfer_needs\""
        , "  schema = \"my_service\""
        , "  columns {"
        , "    reservation_id text required"
        , "    hospital_id text required"
        , "  }"
        , "  version = 1"
        , "  shape = \"fnv1a:fec517dae7760b8a\""
        , "  consistency = Eventual"
        , "  feed = subscription"
        , "}"
        , ""
        , "readmodel transfer_decisions {"
        , "  table = \"transfer_decisions\""
        , "  schema = \"my_service\""
        , "  columns {"
        , "    reservation_id text required"
        , "  }"
        , "  version = 1"
        , "  shape = \"fnv1a:d44d218822582783\""
        , "  consistency = Eventual"
        , "  feed = subscription"
        , "}"
        , ""
        , "workqueue reservation_work {"
        , "  queue logical = \"my_service.reservation_work\""
        , "  derive physical = \"my_service_reservation_work\""
        , "         dlq = \"my_service_reservation_work_dlq\""
        , "         table = \"pgmq.q_my_service_reservation_work\""
        , ""
        , "  payload ReservationWorkItem {"
        , "    reservationId -> \"reservation_id\" text required"
        , "    hospitalId -> \"hospital_id\" text required"
        , "  }"
        , ""
        , "  retry maxRetries = 3 delay = 5s dlq = on"
        , ""
        , "  disposition {"
        , "    storeFailure -> retry 5s"
        , "    commandRejected -> deadLetter"
        , "    decodeFailure -> deadLetter"
        , "    onCodecReject -> deadLetter"
        , "  }"
        , "}"
        , ""
        , "dispatch reservation_work_dispatch {"
        , "  source readModel = accepted_transfer_needs key = reservationId"
        , "  fanout body = resolveTransferCandidates"
        , "  dedup key = reservationId"
        , "        seenIn readModel = transfer_decisions field = reservation_id"
        , "        seenIn queue = reservation_work field = reservation_id"
        , "  enqueue to = reservation_work"
        , "}"
        ]

workflowSkeleton :: Text
workflowSkeleton =
    T.unlines
        [ "context my-service"
        , ""
        , "workflow HospitalTransferReservation"
        , "  name \"hospital-transfer-reservation\""
        , "  in ReservationWorkflowInput { reservationId:Id hospitalId:Id }"
        , "  out ReservationWorkflowSummary"
        , "  id from input.reservationId via idText"
        , "  body"
        , "    step create-transfer-hold -> ReservationHold"
        , "    await reservation-confirmation -> ReservationConfirmation"
        , "    step summarize-reservation -> ReservationWorkflowSummary"
        , ""
        , "operation SignalReservationConfirmation"
        , "  signal reservation-confirmation of HospitalTransferReservation"
        , "    key from reservationId via reservationWorkflowId"
        , "    value ReservationConfirmation"
        , ""
        , "operation RunReservationWorkflow"
        , "  run HospitalTransferReservation"
        , "    input ReservationWorkflowInput"
        , "    outcome -> ReservationWorkflowRun"
        ]
