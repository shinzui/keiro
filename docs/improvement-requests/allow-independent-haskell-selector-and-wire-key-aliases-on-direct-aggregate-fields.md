---
type: Improvement Request
title: Allow independent Haskell selector and wire-key aliases on direct aggregate fields
description: >-
  Separate a direct aggregate field's DSL identity, generated Haskell selector, and serialized
  wire key so reserved names and brownfield contracts do not force domain renaming.
timestamp: 2026-07-31T15:03:54Z
requestId: IR-6
status: completed
origin: mori://shinzui/keiro
plan: docs/plans/192-decouple-wire-keys-from-generated-haskell-selectors-with-field-aliases.md
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T15:03:54Z
    document_timestamp: 2026-07-31T15:03:54Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review of direct aggregate Field lowering versus structural mapped WireField,
      whose syntax already separates a Haskell selector from a quoted wire key.
---

# Improvement Request: Allow Independent Haskell Selector and Wire-Key Aliases on Direct Aggregate Fields

## Status

**Implemented.**
[Plan 192](../plans/192-decouple-wire-keys-from-generated-haskell-selectors-with-field-aliases.md)
under [MasterPlan 29](../masterplans/29-stabilize-keiro-dsl-for-wide-adoption.md) separates DSL
identity, generated selector, and wire key for direct aggregate command/event fields and widens
the request to integration-contract event fields because the motivating Mori regression was on
that public surface. Language-4 syntax, check-time namespace collisions, alias-aware generated
records/codecs/goldens, `fields(Command)` propagation, fold neutrality, diff/replay
classification, and compiled aggregate/contract conformance now cover the requested contract.

## Context

A direct command or event field currently has one name. That name is used as the DSL reference,
feeds the generated Haskell record selector, and determines the JSON key. Those are three different
namespaces. A domain field such as `command`, `type`, or another reserved/awkward Haskell name can
force an author to rename it to `commandName`; that also changes the serialized key to
`commandName`, even when an existing wire contract requires `command`.

Structural mapped records already express the separation as a Haskell field `as "wire_key"`, but
direct aggregate fields have no equivalent alias contract.

## Requested Change

Let each direct command/event field retain a stable DSL identity while optionally declaring an
independent generated Haskell selector and quoted wire key. Define canonical syntax, collision and
reserved-word validation, JSON codec behavior, `fields(Command)` propagation, pretty printing,
workspace merging, scaffold records, fingerprints, and diff/replay classifications.

## Acceptance

1. A field with DSL identity `command`, Haskell selector `commandName`, and wire key `command`
   scaffolds and round-trips without domain or wire renaming.
2. Selector collisions, wire-key collisions, invalid Haskell identifiers, and reserved selectors
   fail during `keiro-dsl check` at the field.
3. Changing only the selector is classified as Haskell source impact; changing the wire key is
   classified against private/public codec and replay surfaces.
4. Shorthand fields without aliases retain current generated output.
5. `fields(Command)` copies the resolved identity/aliases deterministically rather than recomputing
   names in the event renderer.

## Requested Deliverables

- Grammar, checked field-identity model, pretty printing, and diagnostics.
- Alias-aware scaffolding, codecs, manifests, records, diff, and replay impact.
- Positive, collision, reserved-name, brownfield-wire, and mutation tests.
- Authoring and evolution documentation.
