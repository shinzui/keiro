---
type: Improvement Request
title: Support first-class aggregate Time and Natural lowering
description: >-
  Make direct aggregate timestamp and natural-number fields scaffold to their truthful Haskell
  types, and make keiro-dsl check reject every type the selected scaffold cannot lower.
timestamp: 2026-07-31T13:41:01Z
requestId: IR-4
status: proposed
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-07-31T13:41:01Z
    document_timestamp: 2026-07-31T13:41:01Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      In-repository review against Keiro's parser, validator, resolved mapped-type graph,
      scaffolder, generated codecs, snapshots, and conformance harness; the Mori-resolved Keiki
      source at commits af8a14f and 7a93fa5; and the published keiki-0.5.0.0 Hackage release and
      matching upstream v0.5.0.0 tag that contain those changes.
---

# Improvement Request: Support First-Class Aggregate `Time` and `Natural` Lowering

## Status

**Proposed, technically validated.** This blocks Mori MasterPlan 22 from scaffolding its Project
and ProjectArtifact aggregates without weakening timestamps to `Text` and revision numbers to
`Int`.


## Context

Keiro 0.5.0.0 has two inconsistent type surfaces. The resolved mapped-type graph treats `Time`
and `Natural` as first-class scalar types, lowering them to `Data.Time.Clock.UTCTime` and
`Numeric.Natural.Natural`. Aggregate command and event fields also parse bare annotations such as
`observedAt:Time` and `revision:Natural`, and `keiro-dsl check` can accept the resulting spec.

The aggregate scaffolder independently admits only `Text`, `Int`, `Bool`, the generated vertex,
declared IDs and enums, and mapped declarations. A checked aggregate therefore fails later with
`FieldTypeUnrepresentable`; a `Time` or `Natural` register similarly fails with
`RegTypeUnsupported`. The generated Domain and Harness modules also lack imports and sample values
for these direct scalars.

For example, this specification passes semantic checking but cannot be scaffolded:

```text
context observation

aggregate Observation
  regs
  states Pending Recorded!
  command Record { observedAt:Time revision:Natural }
  event ObservationRecorded = fields(Record)
  Pending -- Record --> emit ObservationRecorded ; goto Recorded
```

Using `Text` for `observedAt` moves timestamp validity, ordering, normalization, and wire-format
policy out of the type system. Using `Int` for `revision` admits negative values. Both substitutions
make the model less truthful solely to satisfy a code generator.

This is narrower than IR-1. IR-1 added structural consumer-owned types and nested scalar
expressions. IR-4 closes the remaining gap for those same built-in scalars when they are used
directly by an aggregate and closes the validation/scaffolding split that exposed the gap.


## Requested Change

Add one resolved aggregate-type capability model shared by parsing, validation, diffing,
scaffolding, codec generation, snapshot analysis, and harness generation. For a selected scaffold
target, a successful `keiro-dsl check` must imply that type lowering will not subsequently refuse
the spec.

At minimum, support these direct aggregate scalar mappings:

- `Time` and its accepted alias `UTCTime` lower to `Data.Time.Clock.UTCTime`.
- `Natural` lowers to `Numeric.Natural.Natural`.

Generated Domain, Codec, Harness, Holes, replay-audit, package-obligation, and scaffold-record
outputs must all use the resolved type rather than copying the source token into Haskell. Required
imports must be derived from that same resolution. Event JSON must retain the already documented
wire contracts: Aeson's RFC 3339/ISO-8601 UTC representation for `UTCTime`, and a non-negative
integral JSON number for `Natural`.

Harness samples must be real total values, not `error` placeholders. Timestamp samples must be
stable constants rather than the wall clock. Natural samples must be non-negative.

Register support must be explicit rather than accidental:

- `Time` registers need a typed, deterministic initial-value syntax or a declared fixture symbol;
  generated code must not parse a timestamp at runtime or emit a latent `error`.
- `Natural` register initials must reject negative and non-integral values.
- `Time` guards may use Keiki's existing solver-visible equality and ordering support.
- Keiro must require a Keiki release in which `Natural` has a pinned canonical snapshot identity
  and an unbounded SMT-integer representation constrained to the non-negative domain.
- `Natural` equality and ordering guards use that released Keiki capability. Generic symbolic
  arithmetic remains unavailable until every operation preserves Haskell semantics; in
  particular, Haskell `Natural` subtraction throws `Underflow` when the mathematical result would
  be negative, while ordinary SMT integer subtraction returns that negative integer.
- Snapshot-bearing `Natural` registers use Keiki's pinned `CanonicalTypeName Natural` and the
  generic register JSON codec. Field/event and snapshot tests must reject negative or fractional
  JSON values.


## Validation Contract

Remove the current situation where `validateSpec` and `scaffoldRefusals` maintain incompatible
notions of a valid aggregate type. The authoritative capability must distinguish at least:

1. legal command/event field types;
2. legal register types and their initial-value requirements;
3. types legal in equality, ordering, and update expressions;
4. snapshot-capable types;
5. types for which generated codecs and harness samples are total; and
6. target-specific package/import requirements.

An unknown bare type, a built-in scalar not supported at that use site, or a type expression that
the aggregate grammar cannot represent must produce a stable located diagnostic during `check`.
The scaffold may retain a defensive refusal, but it must be unreachable after a clean check of the
same resolved service/workspace.

`Json`, `Optional`, `List`, and `Map` need an explicit boundary decision in this work. Today direct
aggregate fields cannot express container type expressions, and direct `Json` is refused, while
all four are supported inside mapped structural declarations. It is acceptable to keep mapped
declarations as the aggregate boundary for these shapes, but `check`, notation documentation, and
diagnostics must say so consistently. They must not be silently treated as arbitrary Haskell names
or accepted only to fail during scaffolding.

Keiro's DSL library may remain independent of Keiki at runtime, but its capability table cannot
be an unchecked copy. A conformance component built against Keiki must pin that every DSL
capability claim—equality, ordering, arithmetic, canonical snapshot identity, and JSON
round-tripping—matches the actual released runtime. A Keiki capability removal or semantic change
must therefore fail Keiro CI before a scaffold can advertise the stale capability.


## Acceptance

1. A fixture with direct `Time` command and private-event fields passes `check`, scaffolds, and
   compiles with `UTCTime` in generated domain records.
2. Its generated codec round-trips a pinned sub-second UTC value and a golden JSON timestamp, and
   its generated harness contains no partial sample.
3. A functional transducer copies that timestamp through an emitted event and replays it into a
   register; forward and replayed state agree.
4. Equality and ordering guards over direct `Time` remain solver-visible in Keiki validation.
5. A fixture with direct `Natural` command and event fields scaffolds and round-trips zero and a
   positive value; decoding rejects negative and fractional JSON numbers.
6. Natural equality and ordering guards compile and remain solver-visible; unsupported Natural
   arithmetic is a located validation error rather than an opaque symbolic fallback.
7. Register fixtures pin valid and invalid initial-value behavior separately for `Time` and
   `Natural`, including the snapshot-capability boundary.
8. Unknown types and deliberately unsupported direct `Json` or container uses fail during
   `check`, not only during `scaffold`.
9. A property or table-driven test enumerates every resolved aggregate type/use-site pair and
   proves that clean validation has a total domain, codec, import, initial-value, and harness
   lowering.
10. Existing `Text`, `Int`, `Bool`, ID, enum, vertex, and mapped-type scaffolds remain wire- and
    source-compatible.


## Requested Deliverables

- A shared resolved aggregate-type/capability representation.
- Direct `Time` and `Natural` domain, codec, register, import, and harness lowering, pinned to a
  Keiki release with the required `Natural` domain and snapshot capabilities.
- Validator diagnostics for unsupported types and use-site-specific restrictions.
- Golden, compilation, replay, symbolic-validation, and validation/scaffold parity tests.
- Updated notation and scaffolding documentation, including the direct-container/`Json` boundary.


## References

- Origin plan:
  `mori://shinzui/mori/plans/172-replace-the-project-mirror-with-functional-event-sourced-aggregates`
- Related structural-type request:
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-1`
- Keiro DSL package:
  `mori://shinzui/keiro/packages/keiro-dsl`
- Keiki package:
  `mori://shinzui/keiki/packages/keiki`
