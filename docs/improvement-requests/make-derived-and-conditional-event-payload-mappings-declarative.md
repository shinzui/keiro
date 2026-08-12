---
type: Improvement Request
title: Make derived and conditional event payload mappings declarative
description: >-
  Let Language 5 transitions define total, typed event-field expressions at each emit site,
  including derived and conditional values, while preserving Keiki's static output shape and
  replay-invertibility checks and reserving hand-owned output hooks for genuinely external work.
timestamp: 2026-08-12T02:41:10Z
requestId: IR-25
status: proposed
origin: mori://tan/notification-render-service
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-12T02:41:10Z
    document_timestamp: 2026-08-12T02:41:10Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro's Language 5 expression grammar, EventOutput ownership model,
      generated aggregate lowering and reserved emit-with-braces parser boundary; Keiki 0.9.0.0
      OutTerm, static multi-event-edge, hidden-input, and recompute-and-verify contracts; and the
      notification renderer's authored-versus-rollback RevisionPublished payloads. The request
      does not introduce runtime-variable event arity or weaken replay inversion.
---

# Improvement Request: Make Derived and Conditional Event Payload Mappings Declarative

## Status

Proposed. Raised by `mori://tan/notification-render-service` while reviewing its aggregate model
against the imminent Keiro 0.12 runtime and stable DSL Language 5. The service has explicit event
schemas whose values are completely determined by the accepted command and pre-update registers,
but `event { ... }` plus bare `emit Event` classifies every such payload as a hand-owned output
obligation. Only the narrower `event Event = fields(Command)` identity case is generated-owned
today.

This request generalizes the output-ownership work completed by
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-13`. It does not reopen first-class
collection registers or replace the aggregate-boundary evaluation in
`mori://shinzui/keiro/plans/166-evaluate-bounded-aggregate-collection-membership-and-quantification`.


## Context

Keiro already has nearly all of the ingredients for a checked declarative mapping:

- the Language 5 scalar expression model resolves typed command and register paths, literals,
  comparisons, boolean operators, and structural arithmetic;
- `EventOutputMapping` is the shared ownership model consumed by validation, fold and behavior
  fingerprints, scaffolding, and conformance;
- `fields(Command)` proves generated output construction can replace a create-once output hook;
  and
- the aggregate parser currently accepts bare `emit Event` only when it is not followed by `{`,
  leaving an additive and unambiguous surface for an emit-site mapping.

Keiki 0.9.0.0 also supports derived output values. Its replay algorithm first reconstructs the
command from invertible event fields, then recomputes and verifies fields lowered through
`TArith`, `TApp1`, or `TApp2`. This is the completed contract recorded by
`mori://shinzui/keiki/plans/47-recompute-and-verify-derived-event-outputs-in-solveoutput-replay`.
A derived field remains invalid when it is the only place a command field appears: the event must
still determine the command without inverting an opaque function, and Keiki's hidden-input check
must continue to reject that shape.

The notification renderer exposes the missing Keiro layer. Its `RevisionPublished` schema is
fixed, while different transitions select `Authored` or `RolledBackFrom sourceRevision` origin
values and copy the remaining fields from accepted commands. Those are pure mappings, not
external decisions. Requiring a hand-owned event-output function adds drift-prone code without
adding domain authority.

There are two different meanings of “conditional output,” and the language must keep them
separate:

1. A **conditional payload value** chooses between two values for one declared event field. This
   request makes that a typed expression.
2. **Conditional event presence** changes the number or kinds of events emitted. Keiki represents
   that as separate edges with disjoint guards because every edge has a static output list. This
   request does not add a runtime-variable event list. Authors continue to spell such behavior as
   guarded sibling transitions; future syntax sugar may only lower to those same checked edges.


## Requested Change

1. Add a Language 5 emit-site field mapping for explicitly shaped events. An illustrative surface
   is:

   ```keiro
   emit RevisionPublished {
     templateId = cmd.templateId
     revision = cmd.nextRevision
     content = cmd.content
     origin = cmd.origin
     catalogDigest = cmd.catalogDigest
   }
   ```

   The exact assignment token is a grammar decision, but ownership must attach to one event at one
   transition emit index rather than globally to the event declaration.
2. Require the mapping to be total and exact. Reject missing, duplicate, unknown, or type-mismatched
   fields with source-located diagnostics. Event declaration order, Haskell selector aliases, wire
   keys, and nominal/mapped types remain authoritative and must not be inferred from coincidental
   field names.
3. Reuse the existing typed expression semantics for direct command/register paths, literals, and
   supported arithmetic. Add the minimum total value-expression forms needed for payloads:
   mapped enum/record/union constructors where their bindings support structural construction, and
   `if <boolean expression> then <value> else <value>` with branches of the same resolved target
   type. Do not admit arbitrary inline Haskell or effects.
4. Lower direct command-field copies, register reads, and literals to Keiki's structurally
   invertible term forms. Lower arithmetic, constructors, and conditional values to generated,
   deterministic derived terms where no more precise structural Keiki form exists. Report the
   resulting proof precision honestly; generated ownership does not imply symbolic transparency.
5. Run Keiki's replay contract against the checked mapping. A derived field may be recomputed and
   verified only when every command input remains recoverable from invertible fields in the head
   event. Reject hidden inputs during `check`/scaffold and name the field, command inputs, emit
   index, and remedy. Do not defer this failure to hydration.
6. Keep each checked edge's emitted event vector static. Bare multiple `emit` clauses remain a
   fixed ordered multi-event word. Data-dependent event presence is represented by separate
   disjoint guarded transitions, not by an `if` that returns zero, one, or several events.
7. Preserve `event Event = fields(Command)` as the concise generated identity form and preserve
   bare `emit Event` as the explicit hand-owned mapping form for genuinely custom behavior. If a
   clearer opt-in marker is needed to avoid accidental ownership changes, add it only to Language
   5; Languages 1–4 must retain their frozen parse and scaffold behavior.
8. Include the normalized per-field expression mapping in fold, behavior, source, and conformance
   fingerprints. Diff must classify a mapping change as event-production behavior and apply the
   existing event compatibility and replay-impact rules rather than treating it as formatting.
9. Generate the `OutTerm`/`OutFields` construction directly from the checked mapping and ensure all
   emits in one transition read the same pre-update command/register snapshot, matching Keiki's
   multi-event contract.
10. Expose generated-versus-hand-owned ownership in scaffold ledgers, harness facts, diagnostics,
    and documentation so re-scaffolding cannot retain an obsolete output hook as hidden runtime
    behavior.


## Illustrative Semantics

A redundant derived value is declarative and replay-safe because its inputs are also copied
invertibly:

```keiro
event LineAdded {
  quantity:Int unitPrice:Int lineTotal:Int discounted:Bool chargedTotal:Int
}

Open -- AddLine -->
  emit LineAdded {
    quantity = cmd.quantity
    unitPrice = cmd.unitPrice
    lineTotal = cmd.quantity * cmd.unitPrice
    discounted = cmd.discounted
    chargedTotal = if cmd.discounted then 0 else cmd.quantity * cmd.unitPrice
  }
  goto Open
```

`quantity`, `unitPrice`, and `discounted` reconstruct the command. The two derived fields are then
recomputed and verified. If `lineTotal` were the only field containing `cmd.quantity`, the mapping
would fail the hidden-input check.

For the notification renderer, a nullary authored origin can be a literal constructor and a
rollback origin can be a constructor over the accepted source revision. However, merely nesting
`sourceRevision` inside a derived union value does not make that command field structurally
recoverable in current Keiki. The service must either copy it in an invertible event field, carry a
preconstructed `origin` as the recoverable accepted-command field, or change the aggregate command
shape. This IR removes declarative mapping boilerplate; it does not weaken that replay invariant.


## Acceptance

1. A Language 5 explicitly shaped event with a total `emit Event { ... }` mapping checks and
   scaffolds without a create-once event-output hole.
2. Generated code compiles and emits correct direct command copies, pre-update register reads,
   scalar literals, arithmetic results, supported mapped constructors, and same-typed conditional
   field values.
3. A redundant arithmetic or conditional field round-trips through Keiki replay; mutating the
   observed derived value causes replay to reject it through recompute-and-verify.
4. A mapping whose derived field hides a command input fails before code generation with a stable,
   source-located diagnostic. Adding an invertible copy of that input makes the same mapping pass.
5. Missing, duplicate, unknown, and wrong-typed event fields fail deterministically in both
   single-file and workspace checking.
6. Two transitions may map the same event schema differently without sharing a hand-owned
   function or conflating their fingerprints.
7. Multiple emits retain declaration order and the one-pre-update-snapshot rule. A test attempting
   runtime-conditional event count is refused and points the author to disjoint guarded edges.
8. Changing one field expression produces deterministic behavior/replay/diff evidence and updates
   generated code; whitespace-only or source-reordering-neutral changes do not.
9. Switching a bare hand-owned emit to a complete declarative mapping makes ownership adoption
   explicit, removes only the matching obsolete obligation, and cannot silently reuse stale
   create-once code.
10. Languages 1–4 and existing `fields(Command)` Language 5 sources retain byte-compatible
    parse/check/scaffold behavior.


## Compatibility and Scope

This is a generated behavior feature for candidate Language 5. It does not change persisted event
wire schemas by itself, relax Keiki output inversion, add first-class collection predicates or
updates, decide the notification aggregate boundary, or make event output arity dynamic. Existing
hand-owned output hooks remain the escape hatch for randomness, clock reads not present in the
command, external lookups, and transformations outside the checked expression language.

The feature may expose that a seemingly simple mapping is not replay-invertible. That is a useful
design result, not a reason to hide the check: the event-sourced command shape or event payload
must preserve enough information for deterministic replay.


## Requested Deliverables

- A version-gated grammar and AST for per-emission total field mappings and conditional value
  expressions.
- One checked event-output model shared by validation, lowering, fingerprints, diff, scaffold,
  workspace composition, and behavior conformance.
- Generated Keiki term lowering with hidden-input and recompute-and-verify conformance.
- Positive and negative fixtures for identity, derived, conditional, mapped-constructor,
  multi-event, replay-only, hand-owned fallback, and workspace cases.
- Language reference, output-invertibility, migration, diagnostics, and changelog updates.


## References

- Originating consumer: `mori://tan/notification-render-service`.
- Affected toolchain: `mori://shinzui/keiro/packages/keiro-dsl`.
- Existing identity-output request:
  `mori://shinzui/keiro/okf/improvement-requests/concepts/IR-13`.
- Keiki derived-output contract:
  `mori://shinzui/keiki/plans/47-recompute-and-verify-derived-event-outputs-in-solveoutput-replay`.
- Related collection evaluation:
  `mori://shinzui/keiro/plans/166-evaluate-bounded-aggregate-collection-membership-and-quantification`.
