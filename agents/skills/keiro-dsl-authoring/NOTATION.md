# keiro-dsl notation reference

A `.keiro` file is `context <name>` followed by top-level declarations and nodes. `#` begins a
line comment; whitespace/newlines are insignificant (structure comes from keywords). Every
node family below is parsed, validated, and round-tripped by the toolchain.

Double-quoted strings support `\"`, `\\`, `\n`, `\t`, and `\r`; write line breaks as
`\n` because raw newlines inside a quoted string are rejected. An aggregate may contain
at most one `wire` block and one `projection` block, and each transition must contain
exactly one `goto`; duplicates are positioned parse errors.

## Shared declarations

```text
context hospital-capacity

id   TransferReservationId  prefix=rsv          # an id newtype over Text
enum DivertStatus { Open=open TotalDivert=total-divert }   # Ctor=wire-spelling
rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false
```

Identifiers use ASCII letters, digits, and underscores. Aggregate, process, workflow,
type, and constructor names use `PascalCase`; fields and registers begin with a lowercase
letter or underscore and cannot be Haskell keywords. Generated vertex constructors also
share the constructor namespace: for example, state `Created` in aggregate `Reservation`
generates `ReservationCreated`, so an event with that name is rejected as a collision.

## module placement (optional)

Two optional clauses may follow `context <name>` to control where the emitted modules land. Both
are optional; a spec that omits them scaffolds exactly as today.

```text
context hospital-capacity
module Acme.Services        # optional PascalCase namespace prefix for every emitted module
layout collocated          # placement style: `prefixed` (default) or `collocated`
```

- `prefixed` (default): generated layer at `Generated.<Ctx>.<Node>.*`, holes at `<Ctx>.<Node>.*`
  (a parallel `Generated.*` tree).
- `collocated`: generated layer at `<Ctx>.<Node>.Generated.*` (a leaf under the domain, next to
  hand-written code); holes still at `<Ctx>.<Node>.*`.

With `module Acme` + `layout collocated`: generated → `Acme.<Ctx>.<Node>.Generated.*`, holes →
`Acme.<Ctx>.<Node>.*`. The CLI flags `--module-root`/`--collocate` set the same per invocation and
override the spec clauses (precedence: CLI flag > spec clause > default).

## aggregate (EP-1) + evolution (EP-2)

```text
aggregate Reservation
  regs
    reservationState ReservationVertex = Unrequested      # name Type = initial
    note Text = "not requested"                            # Text initials are quoted
    reservationId TransferReservationId = placeholder     # required sentinel for id registers
    attempts Int = 0                                      # signed integer literals are supported
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
  projection transfer_decisions key=reservationId          # references readmodel by name; consistency= is legacy/optional
    status-map { TransferReservationCreated=>held TransferReservationConfirmed=>confirmed }
                                                             # exact event constructor => status; must be total
    # Or: status-map partial { TransferReservationCreated=>held }
```

Holes (you fill): the transducer body (guards/writes/emits via keiki operators), the
projection SQL `apply`, any `upcast<Event>V<n>` upcaster body.
`status-map partial { … }` opts out of the totality check for events that do not change
the projected status. Every key must still name exactly one declared event constructor;
suffixes such as `Created` do not match `TransferReservationCreated`, and duplicate or
dangling keys are errors. These dangling-key, uniqueness, and totality rules are owned by
the checker; the scaffold's exact lookup is defense-in-depth.

Scaffoldable aggregate register types and explicit command/event field types are `Text`,
`Int`, `Bool`, the aggregate's generated `<Aggregate>Vertex`, and any `id` or `enum` type
declared in the spec. `Text` register initials must be quoted; `Bool` uses `True`/`False`,
`Int` uses a signed integer literal, enum/state registers use an in-domain constructor,
and an id-typed register uses the bare `placeholder` sentinel (lowered to the id newtype's
empty-text placeholder). The scaffolder refuses other types or initial shapes before
writing anything.

All duration windows in the notation are decimal digits followed by exactly one unit:
`s` (seconds), `m` (minutes), or `h` (hours). Thus `5m` means 300 seconds and `2h` means
7200 seconds. This grammar applies to retry delays, timer offsets, and publisher backoff;
unitless values and other suffixes are rejected.

An aggregate may opt into generated snapshots after its projection:

```text
snapshot every 100
  state-codec version=1 shape-hash="<captured-live-hash>"
# Or: snapshot on-terminal with the same mandatory state-codec line.
```

`check` requires an interval of at least 1, a codec version of at least 1, and a
non-empty captured hash. The scaffold derives internal JSON instances and lowers the
clause to `Every n` or `OnTerminal` plus `defaultStateCodec version`. Runtime stream
construction proves policy/codec coherence and initial-state encodability. The hash is
module-qualified Haskell shape data and cannot be derived by `check`: scaffold with a
placeholder, run `keiro-dsl-conformance-snapshot`, copy the printed live hash into the
spec, regenerate, and rerun. Snapshot JSON is internal and gated by both codec version
and shape hash; it is independent of the event wire format. Custom snapshot predicates
remain hand-owned behavior and are intentionally absent from the notation.

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
  rejected => halt                                      # halt | deadLetter | skip; includes CommandAmbiguous
  poison => halt                                        # halt | deadLetter | skip; callback supplied at runtime
  timer surgeFollowUp
    id uuidv5 "hospital-surge-timer:" <> correlationId
    fireAt input.observedAt + 5m                          # TIME INJECTED, not sampled
    payload { kind="hospital-surge-follow-up" hospitalId }
    fire dispatch Surge@correlationId MarkSurgeTimerFired { hospitalId timerId }
      fired-event-id uuidv5 "hospital-surge-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
    max-attempts 5 dead-letter "surge timer exceeded ceiling"   # forces the dangerous default OFF
```

Checked: fireAt must reference a `:Time` input field; no user dispatch-id; saga/target/fire
targets resolve; worker policies agree with disposition arms; `on-ambiguous Fired` is
forbidden because ambiguity is an aggregate-definition bug. The generated `WorkerOptions`
must be passed to `runProcessManagerWorkerWith`; `CommandAmbiguous` follows the node's
`rejected` policy for ordinary dispatches. Holes: the `handle` body, the deadline window,
the fire command, and SQL. An `on-duplicate AckOk` hand-written path must use
`confirmBenignDuplicate` against the target stream before acknowledging the duplicate.

## router (EP-108)

```text
router PagingRouter
  name "jitsurei-paging"                       # stable input to every dispatch id
  input IncidentRaised { incidentId service }
  key input.incidentId via idText
  resolve stable via read-model service_oncall row { responderId }
  target Page
  projections [ ]
  dispatch-each SendPage { incidentId=input.incidentId responderId=resolved.responderId }
    on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
  dispatch-id strategy=uuidv5 from=(name, key, sourceEventId, targetStreamName, occurrence)
  rejected => deadLetter
  poison => halt
```

`resolve stable` is a required acknowledgement: retry attempts deduplicate targets they
resolve again, but a drifting resolver accumulates the union of all attempt outputs. Use
`via read-model <name>` for a declared first-class read model or `via hole` for another
typed effectful resolver. Bindings may read declared `input.*` and `resolved.*` row fields.
The target aggregate and command must resolve. Router name, key derivation, and target are
identity-bearing and therefore Breaking in `diff`. The generated `WorkerOptions` must be
passed to `runRouterWorkerWith`; dispatch-level `CommandAmbiguous` follows `rejected =>`.

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
  persist = dedupe-only                                  # optional; default full-envelope
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
  backoff exponential 2s max=60s multiplier=2.0 ; outboxId stable from messageId
}
```

Checked: complete disposition table + the three inversions; `_ => skip` present; contract/
topic/event coupling resolves; publisher→emit resolves. Publisher backoff is either
`backoff constant <window>` or
`backoff exponential <initial> max=<window> multiplier=<decimal>`. Exponential backoff
requires both clauses; the scaffolder refuses to invent a maximum or multiplier.

`persist = full-envelope | dedupe-only` controls only successful inbox rows and
defaults to `full-envelope` when omitted. The generated `inboxPersistence` value is
passed to `runInboxTransactionWith`. Choose `dedupe-only` only when the payload is
re-fetchable or worthless after success: those rows keep dedupe/operator correlation
but decode with an empty payload. Failed rows always retain the full envelope because
they are the operator-facing dead-letter record.

Delegated-idempotence intake is intentionally absent here: its runtime has not landed,
and `docs/plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md`
owns that future DSL surface. Kafka sharding and consumer-group settings are also
absent permanently; they vary by deployment and remain hole-kind 8 runtime config,
not deterministic service semantics.

## workqueue / dispatch (EP-5)

```text
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"   # captured fixture trio; validator re-derives physical/dlq/table and checks drift
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"
  ordering fifo-throughput                               # default: unordered; also fifo-roundrobin
  group key from reservationId via raw                   # required exactly when ordering is FIFO
  provision standard                                     # default; also unlogged or partitioned(...)
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
  source readModel = accepted_transfer_needs key = reservationId   # must resolve to a readmodel node
  fanout body = resolveTransferCandidates                  # effectful 1->N — HOLE
  dedup key = reservationId
        seenIn readModel = transfer_decisions field = reservation_id # node + declared column must resolve
        seenIn queue = reservation_work field = reservation_id   # raw-SQL — HOLE
  enqueue to = reservation_work
}
```

`ordering` is the consumer's delivery contract. FIFO modes preserve send order within
each declared group while allowing different groups to proceed in parallel; delivery
remains at-least-once, so handlers stay idempotent. `via raw` requires a `text` payload
field. An opaque derivation uses `via <name> fixture "<input> => <output>"` so its
hand-owned implementation can be re-derived consistently.

`provision unlogged` is faster but PostgreSQL truncates the queue to empty after a
database crash, so `check` emits `WqUnloggedDurability`. Partitioned syntax is
`provision partitioned(interval="daily", retention="7 days")`; it requires
`pg_partman`, and these are create-time settings—the additive provisioner does not
migrate an existing queue. FIFO provisioning adds the required GIN index; a DLQ stays
standard. Headers, batch enqueue, visibility timeout, batch size, polling, and metrics
remain deployment tuning (hole-kind 8).

## readmodel (EP-107)

```text
readmodel transfer_decisions {
  table = "transfer_decisions"
  schema = "hospital_capacity"
  columns {
    reservation_id text required
    hospital_id text required
    status text required
    decided_at timestamptz
  }
  version = 1
  shape = "fnv1a:3717f6d9e3c44bd6"
  consistency = Strong
  scope = category "reservation"
  feed = subscription
  subscription = "hospital-capacity-transfer-decisions-sub" # optional override
}

readmodel subscriptions {
  table = "subscriptions"
  schema = "billing"
  columns { subscription_id text required status text required }
  version = 1
  shape = "fnv1a:f54d9bb2f40a6738"
  consistency = Eventual
  feed = inline
}
```

The registry name is `<context>-<node_name_with_hyphens>`; the default subscription name
is `<registry-name>-sub`. `shape` is a captured FNV-1a-64 fixture derived from the table
name and ordered `name:type:req|null` column surface. `check` reports the recomputed value
when it drifts, and changing the declared shape requires a version bump.

`Strong` requires `feed = subscription`; `scope` is legal only with `Strong` and defaults
to `entire-log`. An inline model must be referenced by an aggregate `projection` of the
same name. The projection-level `consistency=` clause is optional legacy syntax; the
readmodel node owns the real default. Query operations and both read-model references in a
dispatch resolve against these nodes; dispatch `field =` also resolves against `columns`.
Generated query/projection holes import a schema-qualified table constant—interpolate it
into SQL instead of depending on PostgreSQL `search_path`.

## workflow / operation (EP-6)

```text
workflow HospitalTransferReservation
  name "hospital-transfer-reservation"
  in ReservationWorkflowInput { reservationId:Id hospitalId:Id coolingOffDelay:Duration }
  out ReservationWorkflowSummary
  id from input.reservationId via idText
  body                                                     # ORDERED; replay matches on label
    step  create-transfer-hold      -> ReservationHold
    patch fraud-check-v2 {                                  # guarded multi-step evolution
      step fraud-check -> FraudCheckResult
    }
    await reservation-confirmation  -> ReservationConfirmation
    sleep cooling-off after coolingOffDelay               # TIME INJECTED
    child ship-order id input via shipChildId -> Text     # child id derived by the via-function hole (see generated hole docs)
    continueAsNew RolloverSeed                             # terminal, top-level rotation

operation SignalReservationConfirmation
  signal reservation-confirmation of HospitalTransferReservation   # MUST match an await label
    key from reservationId via reservationWorkflowId
    value ReservationConfirmation
operation RunReservationWorkflow
  run HospitalTransferReservation
    input ReservationWorkflowInput
    outcome -> ReservationWorkflowRun
operation QueryTransferDecisions
  query transfer_decisions                                 # must resolve to a readmodel node
    input TransferDecisionQuery
    result Maybe TransferDecision
    consistency Strong
```

Operation shapes: `command on <Agg> …`, `query <ReadModel> …`, `signal <label> of <Wf> …`,
`run <Wf> …`. Checked: every `signal <label> of <wf>` matches an `await <label>` of that
workflow (else the awakeable id never matches and the workflow waits forever).

`patch <id> { ... }` guards a cross-cutting workflow change for in-flight instances.
The deploy that introduces the block activates the generated `declaredPatches` set;
the runtime journals the decision under `patch:<id>`, so each generation keeps the
same branch on replay. Patch ids are opaque, never reused, unique across nested blocks,
and may not contain `:`. Rename a single changed step instead of introducing a patch;
use a patch only when adding, removing, reordering, or changing several journaled
steps would otherwise leave an in-flight instance incoherent. Remove a patch id from
the spec only after its guarded change has become permanent.

`continueAsNew <SeedType>` must be the final top-level body item. It rotates an
unbounded workflow onto a fresh journal generation carrying that seed; the hand-owned
workflow body calls `restoreSeed` at its start and `continueAsNew` at its tail. It is
illegal mid-body or inside a patch because later notation would be unreachable or
only conditionally terminal. Workflows intentionally generate facts and live-runtime
wiring only—the behavior-bearing body remains hand code, with no domain scaffold or
hole stub.

## CLI

Run from the keiro repo root (or use the `keiro-dsl/bin/keiro-dsl` wrapper on your `PATH`).

```text
keiro-dsl new      <kind>                       # print a minimal valid skeleton for a node kind
keiro-dsl parse    <file.keiro>                 # parse + pretty-print it back
keiro-dsl check    <file.keiro> [--emit]        # validate; --emit pretty-prints the spec on success
keiro-dsl scaffold <file.keiro> --out DIR \     # validate, emit @generated + holes + manifest, self-check firewall
  [--module-root Acme] [--collocate] [--force-generated-overwrite]
                                                # placement overrides clauses; force is an explicit adoption override
keiro-dsl diff     --since <git-ref> <file.keiro>   # classify ADDITIVE/WARNING/BREAKING since a ref
```

- `new <kind>` — `kind` ∈ aggregate, process, router, contract, intake, emit, publisher, workqueue,
  dispatch, readmodel, workflow, operation. Prints a guaranteed-valid starter spec to stdout
  (`keiro-dsl new aggregate > service.keiro`).
- `scaffold` validates first, then runs collision, firewall, faithful-lowering, and existing-file
  banner gates before writing. Any refusal exits 1 and writes nothing. A Generated target
  lacking `-- @generated` is protected unless `--force-generated-overwrite` is explicitly passed;
  use that override only when replacing the file is intentional. On success it prints modules and
  dispositions, `firewall: OK …`, the harness component, and the manifest path. It also writes a
  `keiro-dsl-manifest.<context>.txt` into `--out` with paste-ready `other-modules:`/`build-depends:`
  blocks for the consuming Cabal stanza, plus a versioned
  `keiro-dsl-scaffold-record.<context>.txt` used on the next run to report stale paths. A `stale:`
  report is informational (exit 0) and never deletes files: Generated entries are safe-to-delete
  candidates; hole entries are hand-owned and must be reviewed first. No manual firewall `grep`
  needed.
- Exit codes gate CI: a non-zero `check`/`scaffold`/`diff` is the signal — fix the **spec**, not the
  generated code. Use `/dev/stdin` as the file to read from stdin.
