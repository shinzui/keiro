---
okf_version: "0.2"
---

# Review

- [Awakeable allocation and legacy derivation API](awakeable-allocation-api.md) - The runtime correctly allocates opaque journaled ids, but its legacy derivation remains easy to mistake for the allocation contract and first-party consumers do exactly that.
- [Awakeable allocation API follow-up](awakeable-allocation-api-follow-up.md) - The authoring API now exposes only opaque journaled allocation, while generation-0 derivation is isolated behind an explicitly named compatibility surface.
- [DSL workflow awakeable signalling conformance](dsl-workflow-awakeable-conformance.md) - The generated helper and its conformance test compare the legacy derivation with itself rather than with the id allocated by the runtime.
- [DSL workflow awakeable signalling follow-up](dsl-workflow-awakeable-conformance-follow-up.md) - Generated workflow support now returns the live allocation id, and its PostgreSQL conformance lane proves that signalling that exact id resumes with the delivered payload.
- [Jitsurei durable workflow example](jitsurei-durable-workflow.md) - The example signals an id the workflow did not allocate, remains suspended, and nevertheless reports that durability was proven.
- [Jitsurei durable workflow follow-up](jitsurei-durable-workflow-follow-up.md) - The runnable workflow now publishes and signals its allocated awakeable id, asserts completion, and proves journal durability across restart with focused regression coverage.
- [Durable workflow user contract](durable-workflow-user-contract.md) - The user guide promises deterministic awakeable ids and at-most-once step effects that the runtime explicitly does not provide.
- [Durable workflow user contract follow-up](durable-workflow-user-contract-follow-up.md) - The user reference and worked guide now match the live effect constraints, opaque awakeable hand-off, and at-least-once step crash semantics.
- [Keiro umbrella version API](keiro-version-api.md) - The exported version and its passing test report 0.4.0.0 while the reviewed package metadata reports 0.11.0.0.
- [Keiro umbrella version API follow-up](keiro-version-api-follow-up.md) - The public version now renders Cabal-generated package metadata, and tests compare it with the same authoritative package version without a duplicate literal.
- [Keiro DSL Language 5 stability gate](keiro-dsl-language-5-stability.md) - The Language 5-exclusive surfaces passed the final adversarial review, but the inherited workflow generator still certifies an awakeable id that the live runtime rejects.
- [Keiro DSL Language 5 stability follow-up](keiro-dsl-language-5-stability-follow-up.md) - Language 5 is now the sole stable authoring contract, Language 4 remains explicit published compatibility, and every exclusive and inherited release surface passes commit-pinned conformance.
