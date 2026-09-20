# Structural text-set conformance

This is the compiled public-authoring example for checked `Set Text` mappings.
It uses a set directly in a named bare mapping and inside a structural record,
`Optional`, `List`, and text-keyed `Map`; the same mapped domain values cross
aggregate command/event/register, workqueue, read-model query, snapshot, event
serialization, and strict multi-event replay surfaces.

The smallest consumer contract is a total `StructuralBinding` between each
domain type and its generated shape. Set parsing and canonical JSON ownership
stay in `Keiro.Codec.TextSet`; bindings never convert through lists or retain
input order or multiplicity. The v1 writer emits ascending unique arrays in
lexicographic Unicode code-point order. The reader accepts permutations and
duplicates and constructs the set before binding or execution. It performs no
Unicode normalization or case folding.

| Surface | Structural text-set status |
| --- | --- |
| Bare and nested structural mappings | Supported and compiled here |
| Aggregate commands, private events, and registers | Supported through named mappings and strict replay evidence here |
| Workqueue payloads | Supported through named mappings and round-trip evidence here |
| Read-model query input/result types | Supported through named mappings and compiled aliases here |
| Cross-file workspace ownership | Supported by the common mapped-type ownership path; the workspace structural suite proves that path |
| Public contract fields | Application-owned codec boundary; no structural mapping syntax is implied |
| Process/workflow journals and effects | Application-owned codecs; sharing `Set Text` does not transfer journal ownership |
| Direct aggregate `Set Text` fields | Unsupported with a located diagnostic; use a named structural mapping |
| Nominal set wrappers | Unsupported in this release |
| Membership, size, ordering, insertion, and removal expressions | Unsupported in this release |

The suite supplies `['b','a','a']` and `['a','b']` to the shared normalization
law. Its replay callback inserts the raw arrays into both events emitted by the
generated transition, parses those stored event values, runs the real generated
transducer, and compares the final vertex and durable register. A mutant that
keeps a list during live execution and deduplicates only while encoding fails
both the domain and replay clauses. A duplicate-rejecting candidate is classified
as versioned compatibility work because v1 has already admitted those bytes.

The historical Aeson codec in this directory models consumer fixtures rather
than retained production history. Real adoption still requires Plan 289's exact
build-pair inventory and Plan 295's consumer stream, queue, projection, process,
and workflow evidence.
