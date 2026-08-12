---
type: Architecture Decision Record
title: Runtime semantics use capability profiles and frozen fold identity
description: Released runtime behavior is selected by explicit monotone capabilities, while replay identity is derived by a total frozen encoder and a fold-only FNV-1a-128 digest.
timestamp: 2026-08-12T04:41:00Z
docId: ADR-18
status: Accepted
date: 2026-08-02
---

# 18. Runtime semantics use capability profiles and frozen fold identity

Date: 2026-08-02

Status: Accepted


## Context

The released-language registry once represented runtime behavior with opaque
identifier strings. Each semantic consumer maintained its own string comparison
or membership list for generated-ID admission, nominal equality, contract-ID
admission, and strict validation. Adding a successor could therefore omit one
list and silently fall back to legacy behavior.

Aggregate fold identity had two related hazards. An unknown runtime-semantics
string minted a new fold segment by default, even when the successor changed no
replay behavior, and the pre-hash surface reused the human-facing pretty
printer. Version registration or presentation-only rendering edits could thus
invalidate snapshots without an intentional fold migration. Resolution failures
could also omit canonical segments, and replay comparison paired same-command
siblings in declaration order.


## Decision

Every released registry row selects a private `RuntimeSemanticsProfile` with a
stable serialized identifier and an explicit set of `RuntimeCapability` values.
Consumers query named capabilities rather than identifiers. Released successor
profiles are monotone, enforced by a registry test.

Each capability exhaustively chooses `Just segment` or `Nothing` for aggregate
fold identity. Profile segments are the deduplicated ascending union. Adding a
capability is therefore a compile-time obligation to decide whether it changes
replay behavior; there is no unknown-identifier fallback that creates identity.
Capabilities for generated-ID admission and exact nominal equality share the
released runtime-semantics-2 segment. Contract-ID admission and strict surface
validation deliberately contribute no aggregate fold segment.

Persisted pre-hash bytes come only from `Keiro.Dsl.CanonicalEncoding`, whose
expression and transition representations are frozen by complete surface
goldens. Presentation pretty printing may evolve independently. Fold surface
construction is total: type-graph, nominal, register, guard, and event-output
resolution failures return `FoldSurfaceError`, which diff, replay-impact,
workspace, CLI, and scaffold planning propagate or refuse before output.
Replay comparison groups transitions structurally, cancels exact and provable
guard-loosening multisets, and sorts remaining canonical values before pairing.

Aggregate fold identity uses a dedicated FNV-1a-128 fold over the canonical
UTF-8 octets. The offset basis, prime, XOR-then-multiply order, and modulo-2^128
arithmetic follow [RFC 9923](https://www.rfc-editor.org/rfc/rfc9923.html); the
result is exactly 32 lowercase hexadecimal characters. This function does not
replace the independent 64-bit read-model shape, mapped-wire, or behavior-key
identities. The width migration is a coordinated pre-`0.9.0.0` snapshot
invalidation and is not a cryptographic security claim.

Identity and evolution APIs require `CheckedService`, retaining the effective
profile alongside the semantic graph. The misleading `Spec`-only fingerprint,
diff, replay-impact, and nominal-equality wrappers are removed; an intentional
legacy caller must cross `legacyCheckedService` explicitly.

`CheckedService` is also the sharing point for pure whole-spec analyses. It is
opaque, retains one lazy resolved type graph derived from its spec, and excludes
that derived value from equality, display, and serialization. Check and scaffold
consumers read the shared graph instead of resolving independently. A caller that
needs a modified graph must use `checkedServiceWithSpec`, which preserves the
effective language contract and constructs a fresh lazy analysis; record updates
cannot pair a replacement spec with stale derived state.


## Consequences

- Registering a successor cannot silently inherit legacy semantics because each
  consumer names the capability it requires and monotonicity is tested.
- A non-fold capability does not invalidate snapshots; adding any capability
  requires an explicit fold-segment decision.
- Pretty-printer changes do not alter persisted replay identity. Changing the
  canonical encoder or digest remains an explicit, golden-backed migration.
- Invalid semantic graphs cannot receive truncated fingerprints or partial
  diff, replay, workspace, CLI, or generated output.
- Replay-impact classification is invariant under sibling declaration order.
- One checked service resolves its type graph at most once across validation,
  planning, generation, conformance, and record construction. Derived analysis
  cannot become stale when a caller replaces the spec.
- The FNV-1a-128 migration invalidates every earlier aggregate snapshot once.
  Events remain authoritative and full replay repopulates compatible caches.
- FNV remains a deterministic change detector, not an authentication or
  adversarial-integrity mechanism.


## Related decisions

- [ADR 0003](0003-snapshot-compatibility-is-a-three-component-discriminator.md)
  defines where aggregate fold identity participates in snapshot admission.
- [ADR 0004](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  defines refusal at the earliest boundary holding enough evidence.
- [ADR 0016](0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  defines the released-language registry and checked service boundary.
