---
type: Improvement Request
title: Let integration contracts describe events owned by other producers
description: >-
  A keiro-dsl integration contract can't express an optional field or a payload without a body
  discriminator, so a Keiro service can't mirror an event published by a service that doesn't
  use Keiro's contract conventions. It must hand-write the payload decoder behind Keiro's
  envelope and inbox runner instead.
timestamp: 2026-11-18T18:21:57Z
requestId: IR-64
status: in-progress
plan: docs/plans/345-let-integration-contracts-declare-optional-fields-and-an-envelope-discriminator.md
origin: mori://tan/agent-reputation-service
relatedPlans:
  - mori://tan/agent-reputation-service/plans/8-resolve-invitations-from-registration-service-v2-completion-events
acceptanceCriteria:
  - id: AC-1
    statement: >-
      A contract field can be declared optional. The generated decoder accepts the field omitted
      or null, the generated type holds it as `Maybe`, and the generated encoder omits it when
      absent.
    verification: >-
      Golden and round-trip tests for a contract with an optional scalar and an optional declared
      id, decoding payloads with the field present, null and omitted.
  - id: AC-2
    statement: >-
      A contract can declare that its payload carries no body discriminator, taking the event type
      from the envelope's `keiro-event-type` instead. This is limited to topics that carry one event
      type or to envelopes that name it.
    verification: >-
      A generated decoder for a one-event topic decodes a bare JSON object with no `messageType`
      key, and rejects an envelope whose `keiro-event-type` doesn't match.
  - id: AC-3
    statement: >-
      The validator keeps refusing optional fields where they would be ambiguous, such as inside
      list elements, and documents which forms are allowed.
    verification: >-
      Negative parse fixtures and the integration-contract section of the user documentation.
reviews:
  - kind: model
    reviewer: claude-code
    reviewed_at: 2026-11-18T16:13:37Z
    document_timestamp: 2026-11-18T16:13:37Z
    scope: technical-accuracy
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      The authoring model's own verification, not an independent review. At keiro commit 2e54849b
      it read the rejection in keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs, line 79: "contract
      field types admit typeid \"prefix\", text, int, a declared id, or List of one of those; ...
      Optional ... not supported in public contracts". It also read the `discriminator` keyword in
      the same parser and the generated `messageTypeOf` in keiro-dsl/src/Keiro/Dsl/Scaffold.hs. It
      checked the foreign payload against registration-service-v2's `RegistrationCompletedV1`.
      Lenient envelope decoding and contract versioning rules are Keiro's to decide.
---

# Let integration contracts describe events owned by other producers

## Problem

`mori://tan/agent-reputation-service` consumes `registration.completed.v1` from
`mori://tan/registration-service-v2`, which doesn't build on keiro-dsl contracts. Its payload is a
bare JSON object. Two of its fields are optional and omitted when unknown: `ownerEmail`, and
`mlsMemberId`, requested in that repository's IR-5. The record names its event type in a header,
not in the body.

A keiro-dsl contract can describe neither property:

- the parser rejects `Optional` in public contract field types
  (`keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`);
- a contract declares a `discriminator`, and the generated decoder reads it from the body.

Declaring `mlsMemberId` as required makes every event published before the field existed fail to
decode. Leaving it out of the contract makes the field unreadable. Either way the consumer can't
use the generated intake, even after the envelope headers are mapped to Keiro's.

The consumer therefore keeps Keiro's envelope decoding and inbox runner, and hand-writes the
payload decoder. Every Keiro service that consumes an event owned by a producer outside Keiro's
conventions repeats that work.

## Request

Let a contract mirror an event that another producer owns:

- **Optional fields:** an optional scalar or declared-id field that decodes when omitted or null
  and is generated as `Maybe`.
- **No body discriminator:** a way to declare that the payload has no discriminator and that the
  event type comes from the envelope, for single-event topics or envelopes that name the type.

## Out of scope

- Mapping a foreign producer's own header names onto Keiro's envelope. The consumer keeps a small
  edge adapter for that until the producer publishes Keiro headers, which is
  `mori://tan/registration-service-v2/okf/improvement-requests/concepts/IR-6`.
- Nested optional containers or optional list elements.
