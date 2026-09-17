---
type: Research Document
title: "Containers in Public Contract Fields: A Postponed Decision"
description: Record why integration-contract fields stay flat scalars for now, what supporting Optional, List, or Map fields on public events would cost, and what must be decided before that changes.
timestamp: "2026-09-17T13:26:25Z"
researchId: RES-18
status: active
scope: Whether keiro-dsl integration contract event fields should admit Optional, List, or Map shapes, and under which rules; the decision is deliberately postponed.
---

# Containers in Public Contract Fields: A Postponed Decision

**Date:** 2026-09-17

**Status:** Postponed decision, captured for a later owner; not an accepted architecture
decision

**Scope:** The field-shape grammar of `contract` declarations in keiro-dsl, which today
admits only `text`, `int`, and `typeid "prefix"` (and, once plan 288 ships, a declared `id`
name).


## Executive Summary

While planning nominal identifier support (IR-40, plans 287 and 288), an audit of every
surface that can carry an identifier found that integration-contract event fields are the only
persisted or public surface with no container shapes at all: no `Optional`, `List`, or `Map`.
That is not an oversight in the same sense as the structural-record gap. Contracts are a
deliberately separate public surface with their own grammar, emitter, compatibility suite,
and evolution rules, and their consumers are other systems, not only Haskell code generated
by keiro. Adding containers is therefore a policy decision about what the public surface
promises before it is an engineering task. No consumer has asked for it. The decision is
postponed; this note records the options, the costs, and the questions that must be answered
first, so the next person to meet the need does not have to rediscover them.


## What Contracts Are Today

A `contract` declares public event names, topic aliases, a schema version, a discriminator,
and flat payload fields. The grammar in `keiro-dsl/src/Keiro/Dsl/Parser/Integration.hs`
accepts three field types (`text`, `int`, `typeid "prefix"`); the generated payload record and
codec are emitted by `emitContractGen` in `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`, entirely
apart from the structural type graph that serves aggregate, queue, and read-model roots.
Public prefixes decode through the TypeID-v7 admission contract when the runtime profile has
`ContractIdDomainTypeIdV7` (plan 171). Evolution is classified separately
(`ContractTypeIdDomainChanged` and the contract field codes in `keiro-dsl/src/Keiro/Dsl/Diff.hs`),
with the rule that a changed public wire key is breaking and consumers deploy before
producers. The `keiro-dsl-conformance-contract-v1-compat` suite freezes the version-1 grammar.
Coverage reports label public contracts "not-applicable (separately owned grammar)"
([ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)).
Contract fields carry independent selector and wire-key identities
([ADR 21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md)).
The integration-events guide (`docs/user/integration-events.md`) anticipates a future schema
registry with Avro or JSON Schema framing, which is to say the audience of a contract is any
system that can read the topic.


## The Question

Should a contract event field be allowed to carry `Optional T`, `List T`, or `Map T`, and if
so, with which wire semantics, which evolution rules, and which authority for `T` when `T`
is not a primitive?


## Options

**Option A. Keep contracts flat; reference declared IDs only.** This is the current
direction. Plan 288 lets a contract field name a declared `id` so a shared prefix change
reaches the public contract in `diff`, without changing field shapes. A producer that needs
a list on a public event flattens it (one event per element, or a JSON-encoded `text` field
that is honestly opaque to keiro).

**Option B. Containers of primitives and IDs, inside the contract emitter.** Extend the
contract grammar with `optional`, `list`, and `map` forms over the existing scalar types
only, and implement their encoders and decoders in `emitContractGen`. Structural
declarations stay out of contracts. This keeps the public surface independent of consumer
Haskell types but duplicates the container codec composition that `Keiro.Dsl.MappedCodecPlan`
already owns for private surfaces.

**Option C. Route contract fields through the structural type graph.** Make contract field
types full mapped type expressions, so a public event can carry a `mapped structural record`.
This maximises reuse but pulls consumer-bound declarations, their bindings, binding
versions, and fixtures into the public surface, where today there are no consumer Haskell
obligations at all, and it makes coverage's "not applicable" label false.


## Costs and Risks

Nullability on a public event needs a language-neutral rule. Private structural records
already distinguish an absent key from a present `null` and forbid `Optional` around a
null-capable value ([ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md)).
A public contract would have to state the same distinction in a form a non-keiro consumer
can implement, and decide whether adding an optional field is additive for consumers that
reject unknown keys.

Element admission needs the same treatment. A `list` of `typeid` values must say whether one
malformed element rejects the whole event and at which path the rejection is reported, in
terms that hold for every consumer language.

Evolution rules multiply. Each container form adds classification cases (element type
changed, optional made required, list made scalar) to the contract vector, and each must be
proven with fixtures in the contract conformance suites; the frozen version-1 suite means
every form arrives behind a syntax feature gate.

Option C changes the public promise. Once a consumer-bound structural declaration is public,
its `binding-version` and canonical identity become facts that other systems depend on, and
a consumer-side binding change becomes a public compatibility event. That is the opposite of
ADR 12's separation of wire authority from consumer build provenance.

Schema-registry framing constrains representation. If contracts are later published as Avro
or JSON Schema, every container form must have a faithful schema rendering; a shape that only
keiro can describe is a liability there.


## What Must Be Decided First

1. Whether the public surface may ever reference consumer-owned declarations (Option C), or
   must remain expressible without keiro (Options A and B).
2. The null-versus-missing policy for public events, and whether adding an optional field is
   additive or breaking for public consumers.
3. Element admission and error-location semantics for lists and maps of `typeid` values.
4. The evolution classification table for each new form, and which existing contract suites
   prove it.
5. How each form renders under the schema-registry framings the integration guide
   anticipates.


## Recommendation

Postpone. Deliver Option A through plan 288. Revisit when a producer has a concrete public
event that cannot be flattened without loss, or when the schema registry work in
`docs/user/integration-events.md` starts, whichever comes first. At that point prefer Option B
unless the consumer of the public event is itself a keiro service and the answer to question 1
is a deliberate yes; record the outcome as an ADR that amends ADR 13's separately-owned
grammar stance, and file an improvement request if the demand comes from another repository.


## Related

- [IR-40](../improvement-requests/support-nominal-ids-inside-structural-mapped-types.md) and
  plans `docs/plans/287-support-nominal-ids-inside-structural-mapped-types.md` and
  `docs/plans/288-complete-nominal-id-support-across-contracts-expressions-nested-enums-and-direct-optional-fields.md`,
  whose audit produced this question.
- [ADR 12](../adr/0012-structural-consumer-mappings-use-one-schema-authority-and-total-bindings.md),
  [ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md),
  and [ADR 21](../adr/0021-direct-fields-have-independent-dsl-selector-and-wire-identities.md).
- [RES-15](14-structural-consumer-type-tradeoffs.md), which records why structural mode
  refuses arbitrary codec reuse; the same reasoning bears on Option C.
