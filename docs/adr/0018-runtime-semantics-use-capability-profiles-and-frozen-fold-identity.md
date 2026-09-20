---
type: Architecture Decision Record
title: Runtime semantics use capability profiles and frozen fold identity
description: Released runtime behavior is selected by explicit monotone capabilities, while replay identity is derived by a total frozen encoder and a fold-only FNV-1a-128 digest.
timestamp: 2026-09-20T03:07:55Z
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

Candidate Language 6's `BareStructuralMappings` capability also contributes no
profile fold segment. The capability authorizes checked syntax and lowering; each
aggregate's existing mapped shape, binding, initial-value, and use-site surfaces
already carry the replay-relevant identity. Services that do not use a bare
declaration therefore keep byte-identical fold fingerprints when the monotone
profile gains this capability.

Candidate Language 6's `CalendarDayMappings` capability likewise contributes no
profile fold segment. It authorizes the checked `Day` structural leaf and complete
lowering through the frozen `keiro-core/calendar-day/1` codec. The calendar policy
identity is embedded in the mapped wire expression, so an aggregate that actually
uses `Day` acquires replay-visible identity through its mapped surface while every
unrelated aggregate retains its existing fold bytes. A future calendar policy must
use a new identity and cannot be hidden behind the same capability or Haskell type.

Persisted pre-hash bytes come only from `Keiro.Dsl.CanonicalEncoding`, whose
expression and transition representations are frozen by complete surface
goldens. Presentation pretty printing may evolve independently. Fold surface
construction is total: type-graph, nominal, register, guard, and event-output
resolution failures return `FoldSurfaceError`, which diff, replay-impact,
workspace, CLI, and scaffold planning propagate or refuse before output.
Ordinary diff and replay-impact analysis share one structural transition-family
partition keyed by mode, source, and command. Each family sorts by frozen
canonical transition bytes and cancels exact values as a duplicate-aware
multiset before either consumer classifies the remainder. Replay impact then
classifies generated live transitions by replay body. Exact remainders select
affected bodies, but every original sibling for each selected body participates
in the complete guard union. Top-level disjunction alternatives are flattened,
sorted, and deduplicated for comparison only; frozen canonical transition bytes
remain unchanged. The same directional syntactic implication fragment proves
preservation for diff and replay impact. Replay-only and no-emit comparison keep
their independent structural treatment. Source location, declaration order,
and forward-only domain outcomes do not participate in exact cancellation or
body identity.

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
- Calendar-day syntax does not globally invalidate snapshots. Its frozen codec
  identity enters only the mapped wire surfaces that use it, and a policy change is
  compatibility work rather than a profile-wide fold-version shortcut.
- Pretty-printer changes do not alter persisted replay identity. Changing the
  canonical encoder or digest remains an explicit, golden-backed migration.
- Invalid semantic graphs cannot receive truncated fingerprints or partial
  diff, replay, workspace, CLI, or generated output.
- Replay-impact classification is invariant under sibling declaration order.
- An identical transition family cannot be replay-neutral while independently
  appearing as a guard change; both projections consume the same exact
  remainder.
- A cancelled sibling can still cover an affected guard alternative because
  body classification recovers complete family membership after work
  selection. Split and merged explicit unions therefore agree across ordinary
  diff and replay impact without changing frozen fold bytes.
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
