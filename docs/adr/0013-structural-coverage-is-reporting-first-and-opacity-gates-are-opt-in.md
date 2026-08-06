---
type: Architecture Decision Record
title: Structural coverage is reporting-first and opacity gates are opt-in
description: Keiro reports named mapped-type authority boundaries without a global percentage, and rejects opacity only under an explicit operator policy.
timestamp: 2026-08-05T23:50:00Z
docId: ADR-13
status: Accepted
date: 2026-07-28
---

# 13. Structural coverage is reporting-first and opacity gates are opt-in

Date: 2026-07-28

Status: Accepted


## Context

Consumer-owned mapped types deliberately have two honest authority modes.
Structural declarations give the `.keiro` graph enough information to generate
and diff private-event wire codecs through total consumer bindings. Opaque
declarations identify a consumer codec and fixture boundary when the structural
grammar cannot express the real invariant. Treating opacity as a soundness
failure would reward authors for making a dishonest structural claim merely to
pass a gate.

The graph also does not represent every persisted surface. It has mapped roots
for aggregate command/event fields and registers. Private events are durable
history owned by the generated codec, but mapped registers are serialized into
snapshots by consumer `ToJSON`/`FromJSON` instances. Queue payloads and public
contracts have separately owned grammars and compatibility rules. Combining
these into one percentage would imply evidence Keiro does not possess.

Brownfield adoption adds a second concern: a structural declaration may be
internally sound but mistranscribe the historical wire contract. A finite
golden corpus can expose differences, but cannot prove universal equivalence
or create a second production codec authority.


## Decision

`Keiro.Dsl.Coverage` reports named boundaries from the checked mapped-type
graph. It constructs complete algebras over resolved declarations, shapes, and
type expressions so a new graph constructor must be handled at compile time.
The stable JSON report has separate inventories for:

- private aggregate event roots, including structural canonical identities,
  opaque codec identities/versions, nested paths, and explicit `Json` leaves;
- mapped aggregate registers, labelled
  `snapshotEncoding = consumer-json-cache` with their wire fingerprint,
  invalidation status, and whether snapshots are currently enabled; and
- queue/public-contract surfaces, labelled unsupported/not-applicable without
  a ratio.

There is no global coverage percentage. `check --coverage-report FILE` emits
the current inventory. `diff --coverage-report FILE` also emits the compared
reference's summary, added/removed named opaque boundaries, and signed deltas.
These options are explicit; an ordinary `check` or `diff` retains its prior
behavior.

Named opaque private-event roots produce the advisory
`CoverageOpaqueSurface`. A newly added boundary produces the advisory
`CoverageOpaqueBoundaryAdded`. Neither raises severity on its own. Operators may
choose the explicit policies `check --fail-on-opaque` or
`diff --fail-on-opaque-increase`, each accepted only beside
`--coverage-report`; a violated policy produces the error
`CoverageOpaqueGateExceeded`. Policy acts on named roots/boundaries, not a
percentage.

Reporting-first governs *severity*, not exemption from the invocation's warning
policy. When `--coverage-report` is supplied, its findings are diagnostics of
that run: `--deny-warnings` and `--deny CoverageOpaqueSurface` escalate them to
a failing exit exactly as they escalate any other warning, and they appear in
the `keiro-dsl/check-report/1` diagnostics array so the report's `ok` accounts
for them. Their declared severity is unchanged either way. A coverage pass that
was reachable by the deny policy in principle but not in practice would make
`check --deny-warnings` a gate with a hole in it, which is the opposite of an
opt-in policy; opt-in means the operator chooses the gate, not that a chosen
gate silently omits a surface.

Historical codec comparison is complementary migration evidence. The
scaffolder may emit an opt-in, non-production module for a structural persisted
type. Consumer code supplies an explicit historical codec and goldens; the
report has only canonical JSON parity or required version/upcaster work, plus
invalid-input and branch-gap failures. It carries mandatory authority framing:
after cutover the generated structural codec is the sole wire authority. The
runner is never a runtime fallback and can never upgrade an opaque declaration.


## Consequences

- CI can track adoption level and drift direction without changing the default
  correctness gate.
- Teams may freeze new opacity before requiring a fully structural corpus.
- Honest opaque declarations remain preferable to unsound structural ones.
- Snapshot reporting remains explicit about consumer JSON and cache
  invalidation; event-codec coverage is never relabelled snapshot-codec
  coverage.
- Queue payloads and public contracts remain visible as unsupported surfaces
  instead of disappearing from a denominator.
- Finite historical comparison must be combined with generated conformance,
  explicit versions/upcasters for differences, and the real-log replay audit.


## Alternatives considered

**Fail every opaque declaration by default.** Rejected because opacity can be
the only sound representation of a consumer invariant, and changing default
`check`/`diff` behavior would turn an adoption metric into a correctness claim.

**Publish one structural-coverage percentage.** Rejected because event roots,
snapshot caches, queue payloads, and public contracts have different owners and
different available evidence.

**Run both codecs in production and select whichever accepts a payload.**
Rejected because it creates two wire authorities, makes rollback semantics
ambiguous, and can silently normalize differences that require an explicit
version boundary.


## Related decisions

- ADR 0003 defines snapshots as a separately invalidated cache boundary.
- ADR 0004 assigns evolution checks to the earliest sound evidence boundary.
- ADR 0012 defines structural mappings, total bindings, opaque mode, and the
  single private-event schema authority.
