# Calendar-day conformance

This is the compiled public-authoring example for checked calendar-day mappings.
It uses `Data.Time.Calendar.Day` directly in a named bare mapping and inside a
structural record, `Optional`, `List`, and text-keyed `Map`; the same mapped
domain values cross aggregate command/event/register, workqueue, read-model
query, snapshot, event serialization, and strict multi-event replay surfaces.

The smallest consumer contract is a total `StructuralBinding` between each
domain type and its generated shape. Calendar validation and JSON ownership stay
in `Keiro.Codec.CalendarDay`; bindings do not convert through `Text`, `UTCTime`,
locale, timezone, or partial smart constructors.

| Surface | Calendar-day status |
| --- | --- |
| Bare and nested structural mappings | Supported and compiled here |
| Aggregate commands, private events, and registers | Supported through named mappings and strict replay evidence here |
| Workqueue payloads | Supported through named mappings and round-trip evidence here |
| Read-model query input/result types | Supported through named mappings and compiled aliases here |
| Cross-file workspace ownership | Supported by the common mapped-type ownership path; the workspace structural suite proves that path |
| Public contract fields | Application-owned codec boundary; no structural mapping syntax is implied |
| Process/workflow journals and effects | Application-owned codecs; sharing `Day` does not transfer journal ownership |
| Direct aggregate `Day` fields | Unsupported with a located diagnostic; use a named structural mapping |
| Nominal `Day` wrappers | Unsupported in this release |
| Date guards, ordering, and arithmetic | Unsupported in this release |

The JSON files under `fixtures/codec-compare` are repository fixtures modeled on
the consumer's Aeson 2.2 `Day` codec, not evidence from retained consumer
history. Real-history adoption and journal audit remain outside this suite.

Aeson 2.2's historical reader rejects years wider than fifteen digits while the
new full-carrier writer can emit them. The suite retains that failed
old-reader/new-writer direction explicitly. Rollout must therefore keep
extended-year writes disabled until old readers are retired (producer last);
historical-read success does not imply simultaneous-version write compatibility.
