# Explicit ID admission domains

Language 6 ID declarations may opt into the frozen `typeid-v5-or-v7` admission
domain when retained data contains canonical TypeIDs derived from either UUIDv5
or UUIDv7:

```keiro
language keiro-dsl 6
context identity-history

id LegacyId prefix=legacy domain=typeid-v5-or-v7
```

Omitting `domain` keeps the existing `typeid-v7` behavior and its compatibility
identity. The option controls which canonical values readers and public
constructors admit. It does not select an ID generator, change deterministic
seeds, or authorize regenerating stored identifiers.

The compiled example is
[`test/fixtures/id-admission-domains.keiro`](../keiro-dsl/test/fixtures/id-admission-domains.keiro),
with its total consumer binding in
[`Bindings.hs`](../keiro-dsl/test/conformance-id-admission-domains/Conformance/IdAdmissionDomains/Bindings.hs)
and executable assertions in
[`Main.hs`](../keiro-dsl/test/conformance-id-admission-domains/Main.hs).
The fixture commits one UUIDv5 value and one UUIDv7 value, then exercises both
through generated event, structural, keyed-map, workqueue, and public-contract
codecs. The generated aggregate harness serializes emitted events, decodes them,
strictly replays them, and compares the final state and registers.

## Supported-use matrix

| Surface | Status and evidence |
| --- | --- |
| Direct aggregate commands, events, and registers | Supported. The compiled `IdentityLedger` fixture uses the declared ID directly and its generated harness checks forward execution against serialized replay. |
| Nested records and optional fields | Supported. `IdentityEnvelope` contains required and optional ID leaves; total binding and codec round trips cover UUIDv5 and mixed UUIDv5/UUIDv7 fixtures. |
| Bare containers and list/text-map nesting | Supported through the checked structural expression graph. The bare-container and structural-nominal conformance suites cover those carriers; the selected admission remains attached to the nominal leaf. |
| ID-keyed maps | Supported. `labelsById` proves canonical key rendering, parsing, and owner reconstruction for retained UUIDv5 keys. |
| Workqueue payloads | Supported. `IdentityWork` carries both a direct ID and the nested envelope through its generated queue codec. Queue draining and rolling-reader deployment remain application obligations when admission changes. |
| Read-model query types | Supported as build-time checked types through the same nominal-leaf graph. A query-only use emits no persisted JSON authority; the structural-nominal and mapped-readmodel suites cover generated query contracts. |
| Workspace ownership | Supported. One context owns each declared domain and workspace composition preserves it; frontend profile and workspace tests cover candidate-language ownership. |
| Public contracts | Supported for declared ID fields. `IdentityLinked` proves UUIDv5 survives the generated public payload codec. |
| Router recipient IDs | Supported through checked nominal identity. Domain changes alter selection identity and remain compatibility findings. |
| Process and workflow codecs | Application-owned. Sharing the ID type does not transfer journal, source-event, child, timer, or continuation codec ownership to Keiro. Applications must retain old readers and prove their own history. |
| Stream names, event IDs, workflow/child/timer IDs, and content-derived IDs | Application-owned immutable identities. Admission only validates existing text; it never changes names, seeds, namespaces, occurrence counters, or generation policy. |

Changing `typeid-v7` to `typeid-v5-or-v7` is a widening with an
old-reader/new-writer hazard: older readers reject newly written UUIDv5 values.
Changing it back is a narrowing with a historical-read hazard: retained UUIDv5
values can stop decoding. Keiro reports either direction as
`IdDomainContractChanged`, changes the affected fold fingerprint, and marks
direct and nested aggregate replay as affected. Rollout evidence must therefore
cover the actual stored surfaces; a successful finite fixture suite does not
retire historical readers.
