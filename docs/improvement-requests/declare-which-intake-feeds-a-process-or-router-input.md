---
type: Improvement Request
title: Declare which intake feeds a process or router input
description: >-
  A process or router declares a typed input but not where it comes from, so the connection from
  an intake's accepted contract events to the component that reacts to them lives only in
  hand-written Haskell. Let a spec declare that source, check it, and expose it as a
  topology edge.
timestamp: 2026-11-16T21:41:12Z
requestId: IR-63
status: proposed
origin: mori://shinzui/mori
relatedPlans:
  - mori://shinzui/mori/masterplans/45-expose-keiro-service-topology-through-a-mori-extension-and-the-http-api
acceptanceCriteria:
  - id: AC-1
    statement: A process or router input can name the intake whose accepted events produce it, alongside the existing typed `input` declaration. A spec that does not name a source stays valid and means what it means today.
    verification: Parser and checker tests over a Language 6 (or later) fixture in which incident-command's CapacityChangeRouter names hospitalInbox as its source, plus an unchanged fixture without a source.
  - id: AC-2
    statement: "`keiro-dsl check` rejects a declared source that does not resolve to an intake in the same service, and an intake source whose `accept` list contains none of the events the input is built from."
    verification: Checker tests asserting a named diagnostic for an unknown intake and for an intake whose accepted events cannot produce the input.
  - id: AC-3
    statement: Once the service-topology export requested in IR-62 exists, a declared source appears as an edge from the intake to the process or router, under a schema id that `/1` consumers will not misread.
    verification: A topology golden test for the source-declaring fixture showing the new edge and the schema id that carries it.
  - id: AC-4
    statement: Generated code and the hand-written binding hole for a source-declaring input keep today's runtime behavior, so declaring a source is a documentation and checking change for existing services, not a runtime migration.
    verification: The keiro-runtime-jitsurei incident-command suite passes unchanged after its CapacityChangeRouter declares hospitalInbox as its source.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-11-16T21:41:12Z
    document_timestamp: 2026-11-16T21:41:12Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. It read `ProcessNode`
      and `RouterNode` in keiro-dsl/src/Keiro/Dsl/Grammar.hs at keiro commit 0b756a65 (input,
      correlate, saga, target and projections, with no source field), and in
      keiro-runtime-jitsurei at commit e3c800e it read the CapacityChangeRouter and
      hospitalInbox declarations in services/incident-command/spec/incident-command.keiro and
      the hand-written AcceptedHospitalCapacitySnapshot construction in
      services/incident-command/src/IncidentCommand/Integration/Inbox.hs. It did not read the
      router runtime or scaffold code.
---

# Improvement Request: Declare Which Intake Feeds a Process or Router Input

## Status

Proposed. It does not block its origin. Mori's planned `keiro` extension reports
cross-service participation at the intake level, and leaves the intake-to-component link out
until keiro can state it.

## Context and evidence

In `mori://shinzui/keiro-runtime-jitsurei`, the incident-command service accepts hospital
capacity snapshots from the hospital-capacity service and reconsiders transfer plans when one
arrives. The spec `services/incident-command/spec/incident-command.keiro` declares both ends.

The intake:

```text
intake hospitalInbox {
  contract emergency
  topic hospitalEvents
  accept HospitalCapacitySnapshotPublished TransferReservationAccepted TransferReservationRejected PatientAdmitted TransferExpired
  ...
}
```

The router:

```text
router CapacityChangeRouter
  name "incident-command-capacity-change"
  input AcceptedHospitalCapacitySnapshot { messageId hospitalId snapshotId region divertStatus availableIcuBeds:Int }
  ...
  target Incident
```

Nothing in the spec says that `AcceptedHospitalCapacitySnapshot` is built from
`hospitalInbox`'s `HospitalCapacitySnapshotPublished` messages. That connection is made in
hand-written Haskell. `services/incident-command/src/IncidentCommand/Integration/Inbox.hs`
defines `AcceptedHospitalCapacitySnapshot`, builds it in
`hospitalCapacitySnapshotFromMessage`, and stores it for the router. In the grammar, `RouterNode`
and `ProcessNode` in `keiro-dsl/src/Keiro/Dsl/Grammar.hs` carry `input`, `correlate` or `key`,
`target` and `projections`, but no source.

The consequence is that every tool that reads the spec sees the inbox and the router as
unrelated:

- keiro-dsl `check` and `diff`;
- the service-topology export requested in IR-62;
- downstream registries such as Mori.

A reader can learn that incident-command consumes `emergency` on `emergency.hospital.events`,
but not which component reacts to it. `check` also cannot catch an intake whose `accept` list
drops the event a router depends on.

## Request

Let a process or router input declare the intake it is fed from. One possible shape is
`input AcceptedHospitalCapacitySnapshot from intake hospitalInbox { ... }`, but the syntax is
keiro's choice, as is whether it arrives in a new language version.

When a source is declared, `check` should verify two things: that it resolves to an intake in
the same service, and that the intake accepts at least one event the input can be built from.
The service-topology export should then carry an intake-to-component edge.

Declaring a source must not change runtime behavior or the binding hole a service already fills.
It records and checks a connection that already exists. If keiro can derive the source soundly
from existing bindings instead of a declaration, that satisfies the request equally well.

## What stays out

The following are out of scope: any change to how intakes deduplicate, decode or persist; moving
the hand-written inbox-to-input conversion into generated code; and sources other than intakes,
such as aggregate event subscriptions, which can be requested separately if needed.
