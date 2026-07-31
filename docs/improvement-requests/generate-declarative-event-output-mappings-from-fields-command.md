---
type: Improvement Request
title: Generate declarative event output mappings from fields(Command)
description: >-
  Keep identity event copies generated-owned when fields(Command) fully specifies their output,
  reserving hand-owned output holes for explicit transformations and external decisions.
timestamp: 2026-07-31T23:44:22Z
requestId: IR-13
status: proposed
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T23:44:22Z
    document_timestamp: 2026-07-31T23:44:22Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Inspected Keiro 0.6.0.0 version-2 scaffold output for Mori and verified that total
      fields(Command) identity mappings remain create-once hand-owned output functions.
---

# Improvement Request: Generate Declarative Event Output Mappings From `fields(Command)`

## Status

Proposed for the version-2 authoritative transducer surface.

## Context

An event declared as `event Accepted = fields(Command)` completely specifies an identity mapping
from the accepted command payload to the emitted event payload. Keiro 0.6 nevertheless scaffolds a
create-once, hand-owned output function that copies every field from the command term into the
event term. The generated transducer calls this hole.

That boilerplate is not a domain decision. Once generated, it can drift from the specification,
survive field evolution incorrectly, or require manual edits merely to restate the schema. It
weakens the claim that version-2 expressions and transducers are authoritative for declared
behavior.

## Requested Change

Generate event output terms directly whenever the event declaration and disposition determine a
total mapping. `fields(Command)` should use the already resolved field identities, selector and
wire aliases, and nominal types. Hand-owned output hooks remain available for explicit field
expressions, transformations, enrichment, generated values, or effectful decisions that the DSL
does not describe.

The generated-vs-hand-owned boundary must be represented in fingerprints, diffs, scaffold records,
and conformance coverage so changing an event from declarative to custom output is visible.

## Acceptance

1. An emitted `fields(Command)` event with compatible fields requires no create-once output hole.
2. The generated transducer constructs the event from the checked command term and compiles with
   direct, aliased, optional, nominal, `Time`, and `Natural` fields.
3. Adding, removing, renaming, or changing a copied field updates generated code and produces the
   appropriate compatibility/replay findings without manual edits.
4. Explicit transformed or externally derived output remains a clearly named hand-owned obligation.
5. Check rejects a disposition whose declarative event output is not total or type-correct.
6. Forward/replay and mutation tests prove the generated mapping is the one used at runtime.
7. Re-scaffolding cannot preserve stale hand-owned identity-copy functions as hidden behavior.

## Requested Deliverables

- A checked event-output mapping model shared by validation, scaffold, diff, and harness code.
- Generated transducer lowering for total declarative mappings.
- An explicit grammar/binding path for genuinely custom outputs.
- Compatibility, replay, scaffold-adoption, and mutation tests.
- Documentation of the generated/hand-owned behavior boundary.
