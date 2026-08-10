---
type: Improvement Request
title: Make ID prefix declarations enforceable and evolution-safe
description: >-
  Give id prefixes a truthful runtime contract for generated and consumer-bound IDs while keeping
  legacy persisted events readable through explicit language-version and migration policy.
timestamp: 2026-08-01T19:21:22Z
requestId: IR-14
status: completed
origin: mori://shinzui/mori
plan: docs/plans/171-enforce-versioned-id-prefix-domains-across-construction-decode-replay-and-evolution.md
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
      In-repository review of generated ID declarations/codecs, nominal bindings, validation,
      fingerprints, diff classification, language versions, and persisted-event compatibility.
---

# Improvement Request: Make ID Prefix Declarations Enforceable and Evolution-Safe

## Status

Implemented in declared language version 3 under
[Plan 171](../plans/171-enforce-versioned-id-prefix-domains-across-construction-decode-replay-and-evolution.md)
and [MasterPlan 27](../masterplans/27-repair-the-keiro-dsl-0-6-language-nominal-generation-and-workspace-regressions.md).
It uses the exact textual projection-domain capability released in Keiki `0.7.0.0` under
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`. Keiro-side design and implementation
keeps the `>=0.7 && <0.8` bound. Current `mmzk-typeid` 0.7.1.1 parsing and version checks are both
part of the frozen runtime contract; existing version-1/version-2 generated-event decoders are not
silently tightened.

## Context

The syntax `id ProjectId prefix=proj` appears to declare a validated identity domain. For an
unbound generated ID, Keiro currently emits a `newtype` over `Text` and decodes any JSON string.
The prefix participates in duplicate-prefix validation, fingerprints, diffs, ID literals, and some
consumer bindings, but does not protect the default generated runtime boundary.

This makes the same declaration mean different things depending on binding mode and lets malformed
or cross-domain IDs enter commands, state, snapshots, and events. Tightening the existing decoder
in place would also be unsafe: persisted historical events may contain values accepted under the
old unchecked contract.

## Requested Change

Define an explicit, versioned ID-domain contract. In the new language version, a prefix-bearing
generated ID must validate its canonical textual representation at construction and external decode
boundaries. Consumer-owned bindings must prove an equivalent domain contract. Legacy unchecked IDs
remain readable according to an explicit migration/upcast policy rather than accidental decoder
behavior.

The contract must specify prefix separators, non-empty suffixes, normalization, maximum length,
JSON representation, Dhall/scaffold literals, error attribution, and whether internal replay can
retain a legacy value that new commands may no longer introduce. Its accepted textual set maps to
Keiki 0.7's exact full-string projection domain for symbolic equality, while Keiro remains the
authority for runtime admission and historical replay policy.

## Acceptance

1. New commands and public decoders reject malformed, empty-suffix, and wrong-prefix IDs with a
   field-located domain error.
2. Generated constructors cannot create an invalid prefix-bearing ID without an explicitly unsafe
   internal API.
3. Two differently declared ID domains remain distinct even when their suffixes match.
4. Consumer-bound IDs provide or derive the same validation contract used by generated IDs.
5. Existing version-1/version-2 event fixtures retain their documented decode behavior.
6. Upgrade/diff output classifies adoption, removal, or change of an enforced prefix across command,
   event, snapshot, replay, and public-codec surfaces.
7. A migration fixture demonstrates replay of a legacy unchecked value and rejection of that same
   value at the new-command boundary.

## Requested Deliverables

- A versioned ID-domain design and compatibility decision.
- Validated generated constructors/codecs plus consumer-binding obligations.
- Upgrade, upcast, diff, replay, and error-attribution support.
- Property tests for accepted/rejected representations, Keiki 0.7 exact-domain agreement, and
  cross-domain confusion.
- Migration and authoring documentation.

## Outcome

Language version 3 selects `keiro-dsl/runtime-semantics/2` and
`keiro-dsl/id-domain/typeid-v7/1`. Generated IDs have an abstract public module with safe parsers
and validating JSON; only the generated internal event codec receives the explicitly unsafe legacy
constructor. Consumer bindings validate through the same contract before conversion and run exact
domain/injectivity conformance probes.

The ID-domain identity is independent of equality and is persisted in single-file/workspace
scaffold records and binding explanations. `IdDomainContractChanged` reports history, rolling
decode, snapshot, public-consumer, persisted-identity, and consumer-build verdicts separately. The
compiled migration fixture accepts legacy malformed event text and rejects the identical current
input at `$.orderId`; its restoring mutation test proves that substituting the current parser for
the legacy replay seam turns the gate red.
