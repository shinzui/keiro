---
type: Architecture Decision Record
title: Aggregate transitions have explicit generated or Hole behavior ownership
description: Each aggregate transition is exclusively generated-owned or explicitly Hole-owned, preserving an honest permanent escape hatch without allowing hand-written code to override checked DSL behavior.
timestamp: 2026-08-10T00:52:02Z
docId: ADR-17
status: Accepted
date: 2026-07-31
---

# 17. Aggregate transitions have explicit generated or Hole behavior ownership

Date: 2026-07-31

Status: Accepted


## Context

Aggregate guard and write expressions are currently rendered as comments in a create-once Holes
module. Consumer code owns the transducer that actually runs. This is a useful escape hatch, but it
also means a checked expression can be ignored or reimplemented with different semantics while
Keiro's diff, replay, snapshot, and symbolic surfaces continue describing the source expression.

Making all transition behavior generated-owned would close that correctness gap but create a
different product failure. A closed expression language cannot anticipate every domain predicate
or register computation. If the generator removes the Hole before the language supports a use
case, users become stuck or are pushed toward dishonest encodings merely to remain inside the DSL.

Partial callbacks such as an additional guard do not solve the general problem. They cannot express
an unsupported register update, and callbacks that override generated values recreate ambiguous
semantic ownership. The boundary needs to preserve a general escape hatch while making it
impossible for a Hole to silently replace behavior that the DSL claims to own.


## Decision

Every aggregate transition in the successor language contract has exactly one behavior owner:
generated ownership or explicit Hole ownership. Ownership is part of the checked semantic graph,
canonical rendering, diff surface, scaffold record, and fold fingerprint.

Generated ownership is the default. Its declared guard and ordered register writes are type-checked,
lowered into structural Keiki terms, and necessarily executed by the generated transducer. A
hand-owned module may construct declared event/output values, but it cannot replace the transition
predicate, reorder or override its writes, or supply an alternative aggregate transducer.

The landed scaffold expresses this boundary with one generated `Transducer`
module per version-2 aggregate. Each generated-owned `B.onCmd` block renders its
checked guard and ordered writes inline beside its emits and target. Nested
projection plumbing is shared only through transition-local `let` aliases; it
does not become a guard/write helper seam. The module exports the assembled
machine, its fold fingerprint, `BehaviorOwnership`, and a labelled
aggregate-specific `...PredicateVerifications` action. No `Expressions` module
is emitted, including for a Hole-only aggregate. The verification action runs the
conservative verifier from `mori://shinzui/keiki/packages/keiki` over each
assembled edge; an opaque predicate reports `UnverifiedOpaque`. Keiki 0.7 also
classifies predicates that cross a one-way projection as `UnverifiedOpaque`.
This changes proof strength only: concrete stepping and replay still execute
the same generated term. An exact projection with a reverse witness is required
when policy needs a `Verified*` classification.

Generated guards may compare IDs and enums only when both operands resolve to
the same nominal declaration. Lowering projects both values through that
declaration's canonical textual key. Finite enums and consumer-bound `KindID`
values use exact domain/reconstruction witnesses. Language-3 generated IDs do
too because safe construction closes their TypeID-v7 domain; version-1/version-2
and legacy-unversioned generated IDs retain a one-way witness and therefore an
honest `UnverifiedOpaque` symbolic result even though concrete stepping and
replay execute the type-safe equality. Cross-
declaration, nominal-to-`Text`, and unqualified enum comparisons fail before
generation. The equality contract and binding provenance enter the fold
fingerprint whenever such a guard uses them.

Event output has the same single-authority rule. A version-2 event declared as
`fields(Command)` is generated-owned only after checking that it names the
transition command and is a total, selector-preserving, type-identical copy.
The generated transducer constructs that event term directly, including
nominal, optional, `Time`, `Natural`, and structurally projected fields; wire
aliases remain codec policy. Explicit event fields retain a hand-owned output
hook because their value transformation is not represented in the language.
Cross-command identity declarations fail before scaffolding.

The source may instead select `implementation hole` for one transition. A Hole-owned transition
does not admit DSL `guard` or `write` clauses: two simultaneous behavior authorities are invalid.
The hand-owned implementation supplies arbitrary Keiki predicate and update terms. Generated code
retains and validates the transition's declared source state, command, emitted event kinds, target
state, and live/replay-only mode as its structural envelope. Conditional outcomes use separately
declared transition alternatives; Hole code cannot invent an undeclared event kind or target.

Hole ownership is a permanent escape hatch. Adding scalar, collection, or other expression features
may let an author migrate a transition to generated ownership, but no feature removes the ability
to select Hole ownership for behavior outside the current language.

Every Hole-owned transition carries an explicit hand-owned `FoldVersion`. That version contributes
to the snapshot/replay-fold discriminator required by ADR 3. Runtime construction validates the
supplied Keiki structure and generated conformance compares forward execution with encoded-event
replay. Structural terms may receive Keiki's ordinary symbolic result. Opaque applications remain
allowed as escape-hatch behavior but are reported as opaque or unverified, never as successful
symbolic proof.

The create-once Holes module exposes one stable function for each Hole-owned
transition and a sibling `...HoleFoldVersion` value. Explicit event-field output
hooks remain hand-owned for both ownership modes, but the generated transducer
calls them inside its declared emit envelope. Generated `fields(Command)`
outputs expose no callback; a stale identity function is reported as obsolete
and cannot affect execution. A Hole function cannot return an alternative
target or event kind because those choices are absent from its interface.
When a version-2 aggregate has no Hole-owned transition and no explicit-event
output hook, scaffolding omits the empty transition `Holes` module entirely;
`BehaviorHoles` remains the separately owned finite conformance witness list.

Each aggregate also has a generated behavior contract and a separate
create-once `BehaviorHoles` witness list. Its finite inventory covers every
live transition from a live-reachable state, every reachable state/command cell
with no live transition, and every replay-only transition. Compiled witnesses
must identify the exact detailed forward or replay edge, cross the generated
codec, and agree on final vertex and all registers. Generated ownership is
labelled source-conformant; Hole ownership remains finite witnessed evidence;
version-1 whole-transducer Holes remain runtime-witness-only. Unknown guard or
projection proof is retained as unverified and is only failing under the
explicit stricter gate.

Generated behavior evidence is human-attributable without changing its stable
identity. Every hash-sorted requirement and newly created pending witness row
annotates the source-state × command cell and obligation kind while retaining
the exact `BehaviorKey` bytes; it does not copy a source position into durable
aggregate or create-once bytes. One generated context `BehaviorSourceMap`
resolves each key to the current exact file, line, and column after a complete
checked join to semantic transition/state anchors. A failed witness carries the
same subject, resolved position, and stable failure code; comparisons report
both actual and expected values in text, and the append-only
`keiro/behavior-conformance/1` JSON object carries the subject in a `subject`
field. Missing, inexact, duplicate, or colliding anchors refuse before scaffold
writes. Presentation must never substitute for evidence: the generated
contract still executes the same finite witness against the runtime transducer
and codec.

One checked source-wide transition layout supplies every generated transition
identity. Each entry retains its one-based declaration index for stable helper
and Hole names and its zero-based outgoing index among all transitions from the
same source for Keiki `EdgeRef` attribution. Rendering consolidates each source
into one `B.from` block in first-source-occurrence order while retaining
transition declaration order within the block. Predicate verification,
behavior requirements, detailed replay witnesses, output mappings, legacy Hole
grouping, and initial live probes all consume that layout; none may regroup
adjacent runs or restart a local edge index. Source blocks are presentation,
not a third transition identity.

Changing ownership is a semantic and replay-affecting change. Diff reports the old and new owner,
the fold fingerprint changes, and snapshot compatibility misses. Migration from an existing
version-1 whole-transducer Hole is manual; regeneration never overwrites consumer code or claims
that behavior has been translated automatically.


## Consequences

- Users can always implement a domain rule or update even when the public expression language
  rejects it.
- A generated-owned expression is authoritative because no Hole seam can replace it.
- Same-declaration nominal equality follows that rule: its checked projection
  identity and domain drive the generated predicate, fold fingerprint, concrete
  execution, replay, and symbolic classification. Enforced language-3 IDs are
  exact; earlier generated IDs remain conservatively one-way.
- A checked `fields(Command)` event copy is equally authoritative and has no
  hand-owned identity callback.
- Hole-owned behavior is honest about its cost: source-level type/capability checks, automatic
  semantic diffing, and symbolic proof are available only to the extent represented by its Keiki
  terms; manual fold versioning remains mandatory.
- The transition grammar, AST, pretty printer, validator, scaffold ownership records, generated
  module firewall, diff, replay impact, and conformance harness must all handle ownership
  exhaustively.
- Future syntax proposals are judged against a real escape hatch. They must demonstrate enough
  verification, reuse, or maintenance benefit to justify permanent language and dependency surface.
- Released version 1 and its create-once whole-transducer Holes remain unchanged. The ownership
  contract lands only under a successor language version with explicit migration guidance.
- Complete finite witness accounting closes initial-state-only conformance
  gaps without claiming universal proof over command values, histories, or
  register valuations.
- Source movement changes the context behavior source map, not behavior keys,
  aggregate contracts, fresh witness comments, folds, or runtime behavior;
  failure rendering still reports the exact current file, line, and column.


## Alternatives considered

**Remove behavior Holes once expressions are generated.** Rejected because users would be unable
to express legitimate behavior outside a necessarily incomplete DSL.

**Let a Hole override any generated transition.** Rejected because checked source, runtime
behavior, symbolic analysis, diff, and replay fingerprints could disagree without a visible
ownership change.

**Provide only an additional custom guard.** Rejected as the universal escape hatch because it
cannot express unsupported register computations. Smaller generated-owned conveniences may be
considered separately, but they do not replace explicit Hole ownership.

**Keep the current implicit whole-transducer Hole for every transition.** Rejected for the
successor language because generated expressions would remain advisory comments rather than an
executable contract.


## Related decisions

- [ADR 0003](0003-snapshot-compatibility-is-a-three-component-discriminator.md) requires manual
  fold versions for hand-written guard/update behavior and composes fold identity into snapshots.
- [ADR 0004](0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires invalid
  mixed ownership and unsupported expressions to fail at the earliest checked boundary.
- [ADR 0012](0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)
  requires checked nested syntax to execute the semantics it validates.
- [ADR 0013](0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md) requires
  honest opacity reporting instead of dishonest structural claims.
- [ADR 0016](0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md) requires the
  new ownership syntax to use a successor language version rather than widening version 1.
