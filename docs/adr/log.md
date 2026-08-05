# Bundle Update Log

## 2026-08-05
* **Update**: Record mode-aware initial live probes, source-wide transition edge identity, and duplicate generated-declaration preflight (plan 191).
* **Update**: Add the field-identity validation, selector-only build advisory, and aggregate/public wire-key evolution boundaries (plan 192).
* **Update**: Make the generated occurrence reserved set exactly the 23 GHC-rejected term identifiers and record the contextual-word compile probe (plan 192).
* **Add**: Define independent DSL, generated-selector, and wire-key identities for direct aggregate and contract fields (plan 192).

## 2026-08-04
* **Update**: Define the generated Haskell naming edition and idiomatic occurrence policy (plan 190).
* **Update**: Record explicit backup-backed source moves for generated-name migrations (plan 190).
* **Update**: Route generated Haskell references through the checked naming plan while preserving consumer identities (plan 190).

## 2026-08-03
* **Add**: Record one opt-in service conformance package, an explicit runtime-package authority, one runtime-owned facade, and create-once service expectations (plan 188).
* **Add**: Record the generated Haskell language and local-extension contract (plan 185).
* **Update**: Record deterministic module-level Haskell import planning: unique consumer types use explicit unqualified imports, collisions and external APIs use stable short aliases, complete identities remain semantic provenance, and create-once modules stay untouched (plan 184).
* **Update**: Make language 4 the stable authoring and primary conformance contract (plan 183).

## 2026-08-02
* **Update**: Record stamped generated banners and the 0.9 generated-API hygiene contract (plan 182).
* **Update**: Record runtime capability profiles, the frozen canonical fingerprint encoder, and the widened snapshot hash (plan 181).
* **Update**: Record check-time policy, duplicate, identity, and envelope gates (plan 180).
* **Update**: Collapse version-2 checked guards and writes into one readable authoritative transducer and make stale generated cleanup depend on exact-banner provenance plus unchanged-byte evidence (plan 179).
* **Update**: Record language-4 typed integration-contract TypeID admission and rollout semantics (plan 178).

## 2026-08-01
* **Update**: Record explicit released syntax/runtime profiles and structured span-aware frontend failure phases (EP-175).
* **Update**: Record located surface syntax and explicit lowering before the normalized Spec graph.
* **Update**: Record language-3 TypeID-v7 admission authority, safe-public and legacy-internal generated ownership, exact nominal domains, snapshot miss behavior, and boundary-specific evolution classification (plan 171).
* **Update**: Record declaration-scoped nominal equality authority, shared-owner projection witnesses, exact consumer ID and enum domains, conservative legacy generated IDs, and generated-transition Hole omission (plan 170).
* **Update**: Amend ADRs 0016 and 0004 with the checked service-level effective semantic contract, explicit legacy `Spec` wrappers, contract-aware planning/fingerprints, additive history, and refusal-before-write boundary (plan 169).
* **Update**: Define the context-level generated Nominals authority, aggregate use-closure imports, and non-destructive Keiro 0.6 layout adoption (plan 168).

## 2026-07-31
* **Update**: Accept ADR 0017 after authoritative scalar transducer conformance landed, and align ADRs 0003, 0004, 0012, and 0016 with generated/Hole ownership, exact arithmetic, conservative verification, and fold-version remedies (plan 161).
* **Update**: Extend ADR 0012's total-binding inventory to consumer-owned direct IDs, enums, and nominal scalars (plan 158).
* **Update**: Extend ADR 0004's earliest-boundary inventory with nominal declaration, provenance-diff, and bound-ID decoder-tightening gates (plan 158).
* **Add**: Propose explicit generated or Hole behavior ownership for aggregate transitions so the escape hatch remains permanent without allowing silent overrides.
* **Update**: Accept ADR 0016 after source-language dispatch, provenance inspection, workspace composition, scaffold history, and replay-neutral diff conformance landed (plan 160).
* **Added**: Record source-language parser dispatch, per-document provenance around semantic Spec, and provenance-only compatibility (plan 160).
* **Update**: Amend ADR 0004 with earliest-boundary direct aggregate type, initial-value, and guard-capability diagnostics (plan 157).
* **Update**: Amend ADR 0012 with the single resolved aggregate type/capability authority and total lowering contract (plan 157).

## 2026-07-29
* **Update**: Record whole-workspace diff composition plus OwnershipMoved and WorkspaceAuthorityChanged advisory boundaries (plan 155).
* **Added**: Record workspace-keyed scaffold history, per-module source ownership, and attributable adoption from per-context records (plan 154)
* **Update**: Draw the diagnostic-code boundary at composition: manifest syntax refusals stay uncoded like spec parse errors (plan 153)
* **Added**: Record the service workspace identity, single-owner member composition, and manifest authority rules (plan 153)

## 2026-07-28
* **Update**: Amend ADR 0004 with reporting-only coverage, opt-in opacity gates, and consumer-compiled historical codec evidence ownership (plan 152).
* **Added**: Record reporting-first mapped-type coverage, named structural/opaque boundaries, and explicit operator-owned opacity gates (plan 152).
* **Update**: Record create-once binding skeletons and exact nominal generic derivation as downstream conveniences under ADR 0012 (plan 151).
* **Update**: Amend ADR 0004 with structural binding, mapped-codec golden, fixture-coverage, and scaffold-drift gate ownership (plan 150).
* **Update**: Accept ADR 0012 after structural binding, codec, projection, replay, mutation, and benchmark conformance landed (plan 150).
* **Update**: Record the landed checked graph, total traversal algebras, root-path expansion, wire-only fingerprints, and synthesized-evidence policy.
* **Update**: Add mapped declaration, recursive evolution, provenance, and weak-golden evidence boundaries to the gate inventory.
* **Update**: Record the compatibility-vector refinement of the diff classification contract.
* **Update**: Record the generated-harness forward/replay equality assertion as the conformance-CI gate for forward-versus-replay state divergence (plan 147).
* **Update**: Name defaultStateCodecWithFold and FoldVersion as the first-class hand-written fold-discriminator contract.
* **Added**: Record one private-event schema authority, total structural bindings, explicit snapshot-cache invalidation, and schema-derived Keiki projection provenance.

## 2026-07-27
* **Update**: Add the scope-sequenced close rule: an unclosed Kafka consumer keeps polling and starves its partitions, so close must never be deferred to the garbage collector.
* **Update**: Extend the consumer contract with the converse obligation: routine partition conditions and idle commits must not kill a consumer, and trace context is per-record.
* **Added**: Record the Kafka consumer fatal-observability contract: fatals are reported in-band as RdKafkaRespErrFatal from every poll in both callback poll modes, via a commit-pinned hw-kafka-client fork.
* **Migration**: Adopt the shared architecture-decision profile.
