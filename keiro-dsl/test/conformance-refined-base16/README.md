# Refined base16 conformance

This compiled public-API example covers `mapped refined` base16 bytes as a bare
mapping, through optional/list/map structural composition, aggregate commands,
events and registers, workqueue payloads, and read-model query types. Process
and workflow journals remain application-owned; `Main.hs` includes an explicit
application-codec round trip without claiming DSL ownership.

The historical codec is a repository fixture modeled from
`mori://shinzui/rei` project-relative
`rei-core/src/Rei/Modules/Knowledge/Domain/Task/Types.hs` and
`rei-core/src/Rei/Modules/Note/Domain/Types.hs` (artifact-level URIs pending).
It is not evidence from Rei's retained production history; that audit belongs
to Plan 295. The generated codec-comparison module runs that modeled reader
against committed empty, leading-zero, mixed-case, uppercase, and arbitrary-
length payloads plus the consumer binding fixtures.

The map composition is a JSON object with refined values. Refined values are
deliberately unsupported as JSON object keys because distinct wire spellings
such as uppercase and lowercase hex would decode to the same bytes.

Supported-use matrix:

- Bare and nested optional/list/text-keyed-map values: generated and tested.
- Aggregate commands, events, registers, snapshots, and replay-only events:
  generated and tested through serialized event envelopes.
- Workqueue payloads and read-model query input/results: generated and tested.
- Public contract fields: unsupported; validation locates the mapped name and
  requires a declared public ID instead.
- Equality, ordering, and arithmetic in aggregate expressions: unsupported;
  validation reports the operator at its source location.
- Process and workflow journals: application-owned. The suite proves the
  explicit codec law but does not infer journal ownership from the shared type.
