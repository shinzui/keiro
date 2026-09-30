# keiro-dsl notation reference

A `.keiro` file begins with the language contract, then `context <name>`, followed by top-level
declarations and nodes. Every source this skill writes declares Language 6:

```text
language keiro-dsl 6
context hospital-capacity
```

The preamble is recognized only after leading comments and whitespace and immediately before
`context`. Nested fields, declarations, wire keys, and strings named `language` remain domain
data. Language 6 extends stable Language 5 with process reactions, delegated inboxes,
`ordering fifo-heads`, nominal structural leaves, `Map[DeclaredId]` keys, declared contract IDs,
bare structural values, `Day`, `Set Text`, `mapped refined` base16 values, and
`domain=typeid-v5-or-v7` ID admission; each is refused below Language 6 with
`LanguageFeatureRequiresVersion`. Languages 1 through 4 and sources without a preamble are
deprecated and scheduled for removal; do not author them. Use
`keiro-dsl inspect <file.keiro> --format=json` to see declared and effective versions.

Language versions select immutable named syntax profiles explicitly; a larger version number does
not inherit features by ordering. When extending the language, add the capability to a new/reused
profile deliberately, implement the production in its single grammar concern, and keep rejection
coverage for every profile that does not own it. Never gate syntax with a raw numeric version
comparison. Canonical parse/pretty output does not preserve comments or whitespace.

`#` begins a line comment; whitespace/newlines are insignificant (structure comes from
keywords). Every node family below is parsed, validated, and round-tripped by the toolchain.

Double-quoted strings support `\"`, `\\`, `\n`, `\t`, and `\r`; write line breaks as
`\n` because raw newlines inside a quoted string are rejected. An aggregate may contain
at most one `wire` block and one `projection` block, and each transition must contain
exactly one `goto`; duplicates are positioned parse errors.

## Shared declarations

```text
language keiro-dsl 6
context hospital-capacity

id   TransferReservationId  prefix=rsv          # a current TypeID-v7 value with prefix rsv
id   LegacyActionId         prefix=action domain=typeid-v5-or-v7   # also admits retained UUIDv5 TypeIDs
id   HospitalId             prefix=hosp
id   CommandId              prefix=cmd
enum DivertStatus { Open=open TotalDivert=total-divert }   # Ctor=wire-spelling
enum PatientAcuity { RedTag=red YellowTag=yellow GreenTag=green }
rule lifeCriticalOverride : PatientAcuity -> Bool
  ex RedTag => true ; YellowTag => false ; GreenTag => false
```

`domain` is `typeid-v7` (the default when omitted) or `typeid-v5-or-v7`. It controls which
canonical TypeIDs readers and public constructors admit, never how IDs are generated. Changing it
in either direction is an `IdDomainContractChanged` compatibility finding: widening risks old
readers rejecting new UUIDv5 values, and narrowing stops retained UUIDv5 values from decoding.

### Consumer-owned nominal declarations

When adopting a binding, add the block to the source, run `parse`, then run
`check --explain-bindings` and fill the create-once binding skeleton. Do not remove the old
generated wrapper from consumer code until the generated tree and compiled conformance harness
are green.

```text
language keiro-dsl 6
context orders

id OrderId prefix=ord using {
  haskell package=orders-domain module=Orders.Id type=OrderId
  binding = "Orders.KeiroBindings.orderIdBinding"
  binding-version = "1"
  canonical-type = "orders.OrderId.v1"
  fixtures = "Orders.KeiroBindings.orderIdFixtures"
}

enum OrderStatus { Draft=draft Submitted=submitted } using {
  haskell package=orders-domain module=Orders.Order type=OrderStatus
  binding = "Orders.KeiroBindings.orderStatusBinding"
  binding-version = "1"
  canonical-type = "orders.OrderStatus.v1"
  fixtures = "Orders.KeiroBindings.orderStatusFixtures"
}

mapped nominal AccountNumber : Text {
  haskell package=orders-domain module=Orders.Account type=AccountNumber
  binding = "Orders.KeiroBindings.accountNumberBinding"
  binding-version = "1"
  canonical-type = "orders.AccountNumber.v1"
  fixtures = "Orders.KeiroBindings.accountNumberFixtures"
  initial = "Orders.KeiroBindings.initialAccountNumber"
}
```

A nominal binding is a total isomorphism between the consumer type and its private-event
representation. IDs use `KindID "prefix"`, enums use a generated closed representation, and
nominal scalars use exactly one of `Text`, `Int`, `Natural`, `Bool`, or `Time`. `initial` is
required when a consumer-bound type is used by a register. Fixtures pair finite consumer values
with expected JSON; they are evidence for the two laws and wire spellings, not proof for all
values. A constructor that can reject, normalize, or identify distinct representation values is
refined rather than nominal: use `mapped refined` when a frozen refined policy fits, otherwise
`mapped opaque`.

Generated domain code imports the consumer type and does not emit a duplicate public wrapper.
The private event codec remains Keiro-owned: it checks the TypeID prefix before constructing the
consumer ID and maps enum JSON only through the generated closed representation. Snapshot caches
still use the consumer's `ToJSON`, `FromJSON`, and `CanonicalTypeName` instances. Bound scalar
registers also receive a context-level `NominalProjections` facade; equality is available for all
five representations and ordering only for `Int`, `Natural`, and `Time`. Bound IDs and enums also
receive declaration-tagged textual equality projections. Consumer `KindID` IDs, generated IDs,
and finite enums are exact. Nominal ordering and arithmetic remain unavailable.

An `id`, `enum`, or `mapped nominal` declaration may also be a leaf inside a structural mapping,
a typed workqueue field, or a read-model query type. The generated shape carries the nominal
domain type, and one context-owned `Structural.NominalLeaves` module applies its binding and
admission wherever a generated codec needs the leaf.

## mapped types

A mapped declaration keeps an application-owned Haskell type at the boundary. A structural
mapping gives the DSL complete authority over its JSON shape; `mapped refined` lowers to a frozen
Keiro wire policy; `mapped opaque` delegates JSON authority to the consumer codec.

```text
mapped structural record ArtifactInfo {
  haskell package=artifact-domain module=Artifact.Domain type=ArtifactInfo
  binding = "Artifact.KeiroBindings.artifactInfoBinding"
  binding-version = "1"
  canonical-type = "artifact.ArtifactInfo.v1"
  fixtures = "Artifact.KeiroBindings.artifactInfoFixtures"
  initial = "Artifact.KeiroBindings.emptyArtifactInfo"   # only when used by a register
  wire object constructor=ArtifactInfo unknown-fields=reject {
    artifactId  as "artifactId"  : ArtifactId              required
    kind        as "kind"        : ArtifactKind            required   # a declared enum leaf
    description as "description" : Optional Text           optional on-missing=null
    tags        as "tags"        : Set Text                required
    publishedOn as "publishedOn" : Optional Day            optional on-missing=null
    owners      as "owners"      : Map[ArtifactId] Text    optional on-missing={}
    digest      as "digest"      : ContentHash             required
  }
}

mapped structural value MaybeLabel {                         # a bare container, no object wrapper
  # haskell/binding/binding-version/canonical-type/fixtures as above
  wire Optional Text
}

mapped refined ContentHash {                                 # lowercase base16 on the wire
  # haskell/binding/binding-version/canonical-type/fixtures as above
  wire base16-bytes
}

mapped structural enum Visibility {
  # haskell/binding/binding-version/canonical-type/fixtures as above
  wire string { Public as "public" Private as "private" }
}

mapped structural union Location {
  # haskell/binding/binding-version/canonical-type/fixtures as above
  wire tagged-object tag="tag" contents="contents" unknown-fields=reject {
    LocalFile as "local_file" : Text
    Unknown as "unknown"
  }
}

mapped opaque VendorGeometry {
  haskell package=vendor-geometry module=Vendor.Geometry type=Geometry
  codec = "vendor.geometry.json"
  version = "3"
  fixtures = "Vendor.Geometry.KeiroBindings.geometryCases"
}
```

Structural type expressions are `Text`, `Int`, `Integer`, `Bool`, `Natural`, `Time`, `Day`,
`Json`, `Optional T`, `List T`, `Map T` (text keys), `Map[DeclaredId] T`, `Set Text`, and the
name of any declared `id`, `enum`, `mapped nominal`, `mapped refined`, or other mapped type.
Optional fields need a type-correct `on-missing` default. The checker rejects recursive mappings,
ill-typed defaults, and `Optional` around a null-capable value (`Optional Json`, or `Optional` of
a value whose root is already `Optional`).

A `mapped structural value` must have `Optional`, `List`, text-keyed `Map`, `Day`, or `Set Text`
as its outer constructor. It is also how an aggregate field or register carries a `Day`, a
`Set Text`, or an optional/collection shape, since those are not legal directly. `Day`,
`Set Text`, and `base16-bytes` lower to frozen `keiro-core` codecs:

| Type | Writes | Reads |
| --- | --- | --- |
| `Day` | `[-]YYYY-MM-DD`, proleptic Gregorian | the same, plus an optional `+` and redundant year zeroes |
| `Set Text` | unique strings in Unicode code-point order | any order, duplicates allowed; no normalization |
| `base16-bytes` | lowercase hex, empty and leading zero bytes preserved | upper- or lowercase hex; no prefix, whitespace, or odd length |

A refined value may be an aggregate field or register, a structural leaf, a list or text-keyed map
value, a typed queue field, or a query type. It is not a map key, not usable in expressions beyond
whole-value writes, and not a public contract field. `Map[K] T` requires `K` to name an `id`.

Every structural and refined declaration creates a create-once binding skeleton. The binding is a
total isomorphism between the consumer type and the generated shape; never validate in
`bindingFromShape`. Run `check --explain-bindings` to list every binding, fixture, and initial
obligation. A changed date, set, base16, or ID-admission policy is a semantic change that needs a
retained reader, not a refactor.

Logical identifiers use ASCII letters, digits, and underscores. Keiro derives generated Haskell
names from one checked word segmentation: module segments, types, and constructors use
UpperCamelCase, while values and selectors use lowerCamelCase. For example, `service_oncall`
becomes `ServiceOncall` / `serviceOncall`, `HTTP_server2` becomes `HTTPServer2` / `httpServer2`,
and `ThingID` becomes `ThingID` / `thingID`. Leading, trailing, and repeated underscores are
unsafe and rejected; two names such as `foo_bar` and `fooBar` are rejected when they normalize to
the same occurrence in one namespace. A generated lower-case keyword is rejected too.

Normalization changes Haskell presentation only. Enum wire spellings, event tags, JSON keys,
queue identities, registry/subscription names, and SQL schema/table/column strings retain their
declared external spelling. Explicit consumer-owned `haskell` modules, types, constructors, and
qualified values are validated but never re-cased. Generated vertex constructors also share the
constructor namespace: state `Created` in aggregate `Reservation` generates
`ReservationCreated`, so an event with that name is rejected as a collision.

## module placement (optional)

Two optional clauses may follow `context <name>` to control where the emitted modules land. Both
are optional; a spec that omits them scaffolds exactly as today.

```text
language keiro-dsl 6
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
    note Text = "not requested"                            # Text initials are quoted
    reservationId TransferReservationId = placeholder     # required sentinel for id registers
    attempts Int = 0                                      # signed integer literals are supported
    observedAt Time = "2026-01-02T03:04:05.123456789012Z" # checked ISO-8601, picosecond exact
    revision Natural = 0                                  # non-negative integral literal
  states Unrequested Held Confirmed Expired!              # trailing ! = terminal (no outgoing)

  command RequestTransferReservation { reservationId hospitalId commandId divertStatus lifeCriticalOverride:Bool }
  event   TransferReservationCreated = fields(RequestTransferReservation)
  event   TransferReservationConfirmed v2 { reservationId hospitalId triageNote:Text }
    upcast from v1 = HOLE                                 # EP-2: vN>1 needs a contiguous upcaster hole
  deprecated event LegacyOpened { reservationId }         # removed from write path, still decodable

  Unrequested -- RequestTransferReservation -->
    guard cmd.divertStatus != DivertStatus.TotalDivert || cmd.lifeCriticalOverride
    emit  TransferReservationCreated
    goto  Held

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transfer_decisions key=reservationId          # an implicit inline owner of the same-named standalone readmodel
    status-map { TransferReservationCreated=>held TransferReservationConfirmed=>confirmed }
                                                             # exact event constructor => status; must be total
    # Or: status-map partial { TransferReservationCreated=>held }
```

Scaffolding generates transitions whose expressions are completely represented by the
spec. Holes (you fill) remain for behavior explicitly declared as `implementation hole`, the
projection SQL `apply`, and any `upcast<Event>V<n>` upcaster body.
`status-map partial { … }` opts out of the totality check for events that do not change
the projected status. Every key must still name exactly one declared event constructor;
suffixes such as `Created` do not match `TransferReservationCreated`, and duplicate or
dangling keys are errors. These dangling-key, uniqueness, and totality rules are owned by
the checker; the scaffold's exact lookup is defense-in-depth.

Direct aggregate register types and explicit command/event field types are `Text`, `Int`,
`Bool`, `Time`, `Natural`, the aggregate's generated `<Aggregate>Vertex`, and any `id`,
`enum`, or mapped type declared in the spec. `UTCTime` is accepted as a source alias and
pretty-prints as the canonical spelling `Time`. `Time` lowers to `UTCTime` and adds the
`time` package; `Natural` lowers to `Numeric.Natural.Natural` without adding a non-base
package.

`Text` register initials must be quoted; `Bool` uses `True`/`False`; `Int` uses a signed
integer literal; `Natural` uses a non-negative integral literal; and `Time` uses a quoted
ISO-8601 value such as `"2026-01-02T03:04:05.123456789012Z"`. Time initials are parsed by
`check` and emitted as explicit `UTCTime` calendar/clock constructors, so generated code
does not parse them or consult a clock at runtime. Enum/state registers use an in-domain
constructor, and an id-typed register uses the bare `placeholder` source sentinel. Scaffolding
lowers that sentinel to a deterministic valid current TypeID-v7 sample; it does not
construct an invalid empty-text ID.

A direct aggregate or integration-contract field has **three independent names**, written in
this order:

```text
command Change {
  type haskell payloadType:Text      -- record selector payloadType, wire key "type"
  region as "region_code":Text       -- record selector region,      wire key "region_code"
  family:Text                        -- all three names are "family"
}
```

The first token is the stable DSL identity — it is what fold identity and every cross-spec
reference see, so renaming it is a spec change even when both aliases are preserved.
`haskell <selector>` changes only the generated Haskell record selector; use it when the DSL
name would be an illegal or awkward Haskell field. `as "<wire-key>"` changes only the JSON
key; use it to **preserve a brownfield key** the current `fields=camelCase` convention would
reject, which is the whole reason the alias exists. Omit an alias and that namespace simply
reuses the DSL name, byte for byte — an unaliased field encodes exactly as before.

Because preserving an off-convention key is the point, a wire key is deliberately *not*
checked against the case convention. It is checked for structural usability: non-empty, no
leading or trailing whitespace, no control character. The wire key is the exact bytes of the
encoded field name, so a typoed `as "family "` would ship a permanently mis-keyed public field
that no later rename could fix without breaking consumers. Selector and wire-key collisions
are checked independently, and an aggregate event's wire key may not be the codec envelope key
`"kind"`. `fields(Command)` copies all three identities unchanged.

A bare aggregate field first inherits an exactly matching register type, then tries the
PascalCase field name as a declared id, enum, aggregate vertex, or mapped type, and finally
falls back to `Text`. Equality guards support the five direct scalars and two values of the same
declared id or enum. Enum literals must be qualified as `Type.Constructor`; cross-ID, cross-enum,
nominal-to-`Text`, unqualified enum, and vertex equality are rejected. IDs and enums have exact
symbolic domains. Ordered
comparison is supported for `Int`, `Integer`, `Time`, and `Natural`. `Integer` supports exact
`+`, `-`, and `*`; `Natural` supports the same operators with total monus subtraction. `Int`
arithmetic, division, remainder, mixed numeric types, Time arithmetic, collection arithmetic, and
nominal arithmetic are rejected.

Direct aggregate `Json`, `Optional`, `List`, `Map`, `Day`, and `Set Text` shapes are deliberately
unsupported. Declare a `mapped structural` record or value when an aggregate payload needs one of
those shapes; a `mapped refined` type may be used directly.
`check` reports unknown types, unsupported shapes/use sites, invalid register initials,
cross-type comparisons, and unsupported guard capabilities before scaffolding writes
anything.

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

Language 6 reactions generate the process decision, manager, worker, timer
payloads/builders, and firing dispatcher. The only process Hole is the typed
source decoder `decode<Process>Input :: RecordedEvent -> Maybe <Process>Input`.

```text
process IncidentEscalation
  name "incident-escalation"
  reactions version 1
  input IncidentReported { incidentId:IncidentId severity:Severity raisedAt:Time }
  input ResponderAcked { incidentId:IncidentId ackedAt:Time }
  input IncidentNoted { incidentId:IncidentId }
  correlate input.incidentId via idText
  saga Escalation category "escalation"
  target Hospital
  projections [ ]

  on IncidentReported
    when input.severity == Severity.Sev1
      advance NoteRaised { incidentId }
      schedule escalation fireAt input.raisedAt + 5m { incidentId severity }
    otherwise
      advance NoteRaised { incidentId }
      schedule escalation once fireAt input.raisedAt + 60m { incidentId severity }

  on ResponderAcked
    advance NoteAcknowledged { incidentId }
      accepted
        dispatch Hospital@input.incidentId AcknowledgeIncident { incidentId }
          on-appended AckOk ; on-duplicate AckOk ; on-failed Retry
      silent no-action
    cancel escalation

  on IncidentNoted
    no-action

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, targetStreamName, occurrence)
  rejected => halt
  poison => halt

  timers max-attempts 5 dead-letter "escalation timer exceeded ceiling"

  timer escalation
    id uuidv5 "incident-escalation-timer:" <> correlationId
    payload { kind="escalation" incidentId:IncidentId severity:Severity }
    fire dispatch Hospital@correlationId EscalateIncident { incidentId }
      fired-event-id uuidv5 "incident-escalation-fired:" <> correlationId
      on-ok Fired ; on-reject Fired ; on-ambiguous Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
```

Every declared input has exactly one `on`. Arms are first-match-wins; a `when`
sequence ends in `otherwise`, and an unconditional arm stands alone. Guards are
Boolean and input-only. Saga state access is rejected because the hydrated saga
command is the decision authority. `no-action` has no saga receipt. Follow-ups
beside `advance` are unconditional; those nested beneath `accepted` require a
non-empty accepted append or recovery of its exact witness. An accepted block
also requires the explicit `silent no-action` alternative.

Timers are optional, so a timer-free process ends after the worker policies.
With timers, one `timers` line supplies the process-wide ceiling. `schedule`
defaults to rearm; `schedule <name> once` is insert-only; `cancel` uses the
named timer's generated id. Every schedule supplies all dynamic payload fields.
`fireAt` uses an injected `:Time`, never a sampled clock. Timer and fired-event
prefixes are unique per process and end with `correlationId`. Cancellation does
not revoke a claimed callback; make late firing benign.

The target-keyed dispatch identity counts same-target occurrences in declared
order. `reactions version` and the generated SHA-256 fingerprint are
coordination metadata, not identity seed fields. Increase the version for every
semantic fingerprint change and still follow the diff's drain instructions.
Moving a legacy process body to reactions is a breaking identity migration.

Author new processes as reactions. The older one-input/one-timer process form, with its
positional `emitIndex` identity, is still accepted so existing processes keep their identity; do
not mechanically rewrite one into the other.
An `on-duplicate AckOk` hand-written legacy path must still use
`confirmBenignDuplicate` against the target stream. See `TAXONOMY.md` for the
full `CommandAmbiguous` distinction.

The saga clause names a validated stream **category**, not a raw prefix. Categories are
non-empty, contain no `-`, whitespace, control characters, or `:`, and may not be `$all`;
write compound names in camelCase. The scaffold emits `<process>Category` and one
`<aggregate>Category` constant per aggregate. Hole fills construct streams with
`entityStream` or `entityStreamId` against those constants—never with raw text
concatenation.

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
Maps to a generated `Router` module plus a create-once `RouterHoles` module for the resolver,
target stream/projections, and assembled runtime value. Checked: router/readmodel/aggregate/
command references resolve; key and binding fields are in scope; worker policy agrees with
the dispatch arms; ambiguity cannot be marked benign.

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

`idempotence delegated` after the `dedupe` line hands receipt ownership to the downstream state
machine instead of the inbox table:

```text
  dedupe key messageId policy PreferIntegrationMessageId
  idempotence delegated                                  # optional; omission means `table`
```

It generates the typed `runInboxIntake` wrapper over `runInboxDelegated` and cannot be combined
with `persist = dedupe-only` (`DelegatedInboxDedupeOnlyPersistence`), because delegated mode
writes no inbox rows. Moving between `table` and `delegated` is a persisted-identity break
(`IntakeIdempotenceModeChanged`) that needs an explicit cutover.

Contract fields may name a declared `id` directly instead of `typeid "prefix"`, as in
`reservationId: TransferReservationId`; the field keeps that declaration's prefix, admission
domain, and Haskell type. Only `id` declarations are accepted there.

Kafka sharding and consumer-group settings are absent permanently; they vary by deployment and
remain hole-kind 8 runtime config, not deterministic service semantics.

## workqueue / dispatch (EP-5)

```text
workqueue reservation_work {
  queue logical = "hospital_capacity.reservation_work"
  derive physical = "hospital_capacity_reservation_work"   # captured fixture trio; validator re-derives physical/dlq/table and checks drift
         dlq = "hospital_capacity_reservation_work_dlq"
         table = "pgmq.q_hospital_capacity_reservation_work"
  ordering fifo-heads                                    # default: unordered; also fifo-throughput, fifo-roundrobin
  group key from reservationId via raw                   # required exactly when ordering is FIFO
  provision standard                                     # default; also unlogged or partitioned(...)
  payload ReservationWorkItem {
    reservationId -> "reservation_id" text required       # arrow form: text | int | bool only
    details -> "details" : ArtifactInfo                    # colon form: any mapped type expression
  }
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
remains at-least-once, so handlers stay idempotent. `fifo-heads` is the strict failure
barrier and safely batches independent group heads; prefer it for new FIFO queues. The
older `fifo-throughput` and `fifo-roundrobin` modes require a runtime batch size of one.
Every payload row is required, so adding a row is a breaking queue change. `via raw` requires a `text` payload
field. An opaque derivation uses `via <name> fixture "<input> => <output>"` so its
hand-owned implementation can be re-derived consistently.

`provision unlogged` is faster but PostgreSQL truncates the queue to empty after a
database crash, so `check` emits `WqUnloggedDurability`. Partitioned syntax is
`provision partitioned(interval="daily", retention="7 days")`; it requires
`pg_partman`, and these are create-time settings—the additive provisioner does not
migrate an existing queue. FIFO provisioning adds the required GIN index; a DLQ stays
standard. Headers, batch enqueue, visibility timeout, batch size, polling, and metrics
remain deployment tuning (hole-kind 8).

Maps to generated `Queue` and `QueuePolicy` modules; fanout, worker handling, and raw-SQL
dedupe remain hand-owned. Checked: all four disposition outcomes are present, the transient/
poison inversions are rejected, the captured physical/DLQ/table trio is re-derived, FIFO
and group-key clauses agree, provisioning fixtures are non-empty, and dispatch queue/
readmodel/field references resolve.

## readmodel (EP-107)

A read model is standalone, supplied by the aggregate `projection` of the same name, or
catalog-bound, supplied by a `projection-owner`. A standalone model keeps its table on the node:

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
  freshness = immediate                                   # the only freshness an inline projection reaches
}
```

The registry name is `<context>-<node_name_with_hyphens>`. `shape` is a captured FNV-1a-64
fixture derived from the table name and ordered `name:type:req|null` column surface. `check`
reports the recomputed value when it drifts, and changing the declared shape requires a version
bump. `feed`, `subscription`, `consistency`, and `scope` are not part of the language and are
rejected on a read model. Query operations and both read-model references in a dispatch resolve
against these nodes; dispatch `field =` also resolves against `columns`. Generated
query/projection holes import a schema-qualified table constant—interpolate it into SQL instead
of depending on PostgreSQL `search_path`. Maps to generated `ReadModelTable`, `ReadModel`, and
facts-harness modules plus a create-once `ReadModelHoles` module for inline apply, async apply,
and query behavior.

A catalog separates the writer from the query policy. A projection owner declares delivery, and a
catalog-bound read model declares freshness and its targets instead of a schema or table:

```text
target transfer_decisions_table {
  schema = "hospital_capacity"
  table = "transfer_decisions"
  reset = clear
}

rebuild-group transfer_reporting {
  targets = [ transfer_decisions_table ]
  order = [ transfer_decisions_table ]
}

projection-owner transfer_decisions_writer {
  source = category "reservation"
  delivery = subscription
  group = transfer_reporting
  targets = [ transfer_decisions_table ]
  order = 10
  subscription = "hospital-capacity-transfer-decisions-sub"
  dedup = "hospital-capacity-transfer-decisions-v1"
  checkpoint-on-missing = from-beginning
  replay = explicit
}

readmodel transfer_decisions {
  columns {
    reservation_id text required
    hospital_id text required
    status text required
    decided_at timestamptz
  }
  query input = TransferDecisionQuery                     # optional pair, directly after columns
  query result = Optional TransferDecision
  version = 1
  shape = "fnv1a:bbd9418e1212852d"                        # copy the value `check` prints
  freshness = wait-for-head category "reservation"
  group = transfer_reporting
  targets = [ transfer_decisions_table ]
}
```

Use `freshness = immediate` to run without polling; this is valid for inline or
subscription delivery, and the subscription form may observe lag. A head wait requires one
compatible durable cursor derived from the owner: entire-log requires `source = all`, while
a category wait accepts `all` or the same category. The static language does not encode a
caller position; use the runtime `WaitForPosition` override for read-your-write. Do not also
name a catalog-bound read model from an aggregate-local `projection` clause.

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
workflow (else the awakeable id never matches and the workflow waits forever); signal value
types agree, workflow labels are unique, id/sleep fields and operation targets resolve,
patch ids are unique and colon-free, and `continueAsNew` is terminal and top-level.

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
keiro-dsl inspect  <file.keiro> --format=json   # report declared/effective language provenance
keiro-dsl scaffold <file.keiro> --out DIR \     # validate, emit @generated + holes + Cabal fragment, self-check firewall
  [--module-root Acme] [--collocate] [--force-generated-overwrite]
                                                # placement overrides clauses; force is an explicit adoption override
keiro-dsl diff     --since <git-ref> <file.keiro>   # classify ADDITIVE/WARNING/BREAKING since a ref
keiro-dsl check    <service.keiro-workspace>        # compose and validate all members
keiro-dsl scaffold <service.keiro-workspace> --out DIR
keiro-dsl diff     --since <git-ref> <service.keiro-workspace>
```

### Workspace manifest

A multi-file service uses a separate `.keiro-workspace` file. Each member is still a
complete `.keiro` spec, starts with `language keiro-dsl 6`, and declares the same context.

```text
service demo-project
module Demo.Modules.Project
layout collocated
spec domain/project-artifact.keiro
spec domain/project.keiro
spec domain/shared.keiro
```

`service` is the stable workspace identity. Optional `module` and `layout
prefixed|collocated` clauses are workspace authority; a member clause must be absent or
exactly equal. One or more `spec` paths follow, relative to the manifest directory,
confined beneath it, and ending in `.keiro`. Membership is canonically sorted, so source
order changes neither meaning nor generated bytes. Shared ids, enums, rules, and mapped
declarations have exactly one owning member; identical duplicates do not merge.

- `new <kind>` — `kind` ∈ aggregate, process, router, contract, intake, emit, publisher,
  workqueue, dispatch, workflow, operation. Prints a guaranteed-valid Language 5 starter spec to
  stdout; change its first line to `language keiro-dsl 6` before editing. `readmodel` is a top-level notation node but
  not a standalone skeleton kind; the coupled `new workqueue` starter includes the readmodels
  needed by its dispatch.
- `scaffold` validates first, then runs collision, firewall, faithful-lowering, and existing-file
  banner gates before writing. Any refusal exits 1 and writes nothing. A Generated target
  lacking `-- @generated` is protected unless `--force-generated-overwrite` is explicitly passed;
  use that override only when replacing the file is intentional. On success it prints modules and
  dispositions, `firewall: OK …`, the harness component, and the generated Cabal-fragment path.
  It also writes a `keiro-dsl-cabal-fragment.context.<context>.txt` into `--out` with
  paste-ready `other-modules:`/`build-depends:` blocks for the consuming Cabal stanza — this
  fragment is the authoritative generated build inventory — plus a versioned scaffold ledger
  `keiro-dsl-ledger.context.<context>.txt` used on the next run to report stale paths. A `stale:`
  report is informational (exit 0) and never deletes files: Generated entries are safe-to-delete
  candidates; hole entries are hand-owned and must be reviewed first. No manual firewall `grep`
  needed. A workspace instead writes one
  `keiro-dsl-ledger.workspace.<service>.txt` and one matching
  `keiro-dsl-cabal-fragment.workspace.<service>.<ext>` with per-module member ownership; the
  single-file names remain unchanged. A generated conformance package additionally carries a
  `keiro-dsl-conformance-ledger.txt`. An output tree holding the pre-0.11 names
  (`keiro-dsl-scaffold-record.*`, `keiro-dsl-manifest.*`, `keiro-dsl-conformance-record.txt`)
  refuses without writing and lists every rename; rerun with `--apply-name-migrations`.
- Exit codes gate CI: a non-zero `check`/`scaffold`/`diff` is the signal — fix the **spec**, not the
  generated code. Use `/dev/stdin` as the file to read from stdin.

The workspace manifest itself is unversioned. `inspect <service.keiro-workspace>
--format=json` loads its members and reports each member's source form and effective version in
canonical path order. Every member declares Language 6; members with different effective versions
are refused before semantic graph merge and are not upgraded.
