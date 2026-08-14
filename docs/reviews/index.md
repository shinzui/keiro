---
okf_version: "0.2"
---

# Review

- [Awakeable allocation and legacy derivation API](awakeable-allocation-api.md) - The runtime correctly allocates opaque journaled ids, but its legacy derivation remains easy to mistake for the allocation contract and first-party consumers do exactly that.
- [DSL workflow awakeable signalling conformance](dsl-workflow-awakeable-conformance.md) - The generated helper and its conformance test compare the legacy derivation with itself rather than with the id allocated by the runtime.
- [Jitsurei durable workflow example](jitsurei-durable-workflow.md) - The example signals an id the workflow did not allocate, remains suspended, and nevertheless reports that durability was proven.
- [Durable workflow user contract](durable-workflow-user-contract.md) - The user guide promises deterministic awakeable ids and at-most-once step effects that the runtime explicitly does not provide.
- [Keiro umbrella version API](keiro-version-api.md) - The exported version and its passing test report 0.4.0.0 while the reviewed package metadata reports 0.11.0.0.
- [Keiro DSL Language 5 stability gate](keiro-dsl-language-5-stability.md) - The Language 5-exclusive surfaces passed the final adversarial review, but the inherited workflow generator still certifies an awakeable id that the live runtime rejects.
