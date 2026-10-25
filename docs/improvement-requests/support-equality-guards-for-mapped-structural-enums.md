---
type: Improvement Request
title: Support equality guards for mapped structural enums
description: >-
  Allow a consumer-owned mapped structural enum to participate in exact, type-safe aggregate
  equality guards without introducing a second native enum and an exhaustive adapter.
timestamp: 2026-10-25T17:44:19Z
requestId: IR-60
status: proposed
origin: mori://shinzui/kotei
---

# Improvement Request: Support Equality Guards for Mapped Structural Enums

## Status

Proposed from `mori://shinzui/kotei/plans/103-reconstruct-recorded-failure-environments-for-inspection-and-debugging`.
This is a follow-up improvement, not a prerequisite for that implementation. Kotei can retain
its checked enum adapter and qualify a replacement after an upstream release supports it.

## Context and evidence

Kotei has a consumer-owned `RequiredScope` enum with pipeline and diagnostic alternatives.
It occurs in nested runtime records and is also needed in aggregate guards that compare a
terminal command's scope with its scheduled scope. A single structural binding would keep
the owner type, wire domain and reconstruction contract consistent across both uses.

The current released keiro-dsl 0.21.0.0 rejects this language-6 guard:

```text
guard cmd.requiredScope == reg.requiredScope
```

The standalone reproducer reports
`AggregateExpressionOperatorUnsupported: equality is unsupported for scalar type 'RequiredScope'`.
Its declaration is:

```text
mapped structural enum RequiredScope {
  haskell package=probe module=Example.Scope type=RequiredScope
  binding = "Example.Scope.requiredScopeBinding"
  binding-version = "1"
  canonical-type = "example.RequiredScope.v1"
  fixtures = "Example.Scope.requiredScopeFixtures"
  initial = "Example.Scope.initialRequiredScope"
  wire string {
    PipelineScope as "pipeline"
    DiagnosticScope as "diagnostic"
  }
}
```

The minimal aggregate has a `RequiredScope` register initialized with `initial`, a command
with a field of that same type, and the guard above. The current expression capability
check rejects mapped aggregate scalars. The release version was checked against Hackage
and the upstream `keiro-dsl-0.21.0.0` tag.

[IR-12](make-nominal-id-and-enum-equality-first-class-in-aggregate-expressions.md) and
[Plan 170](../plans/170-make-nominal-id-and-enum-equality-exact-in-aggregate-expressions.md)
already delivered nominal enum equality. Plan 288 also supports nominal enums as structural
leaves. This request concerns the distinct `mapped structural enum` declaration; it does
not claim consumer-bound nominal enums lack equality.

## Current consumer bridge

Kotei keeps the consumer-owned structural `RequiredScope` and introduces a native
`TerminalScope` for direct aggregate guard fields. An exhaustive adapter connects the two
closed domains. Guards stay generated, symbolic and exact; neither a Text shadow register
nor a behavior hole is necessary. This is sufficient to proceed with Plan 103, but duplicates
the enum declaration and requires maintaining the adapter.

## Requested change

Support `==` and `!=` between values of the same mapped structural enum, including command
and register fields and qualified constructors. Preserve declaration identity: unrelated
enums with identical wire alternatives, and enum/Text comparisons, must remain invalid.

Generate a finite, exact symbolic domain for the declared alternatives and reconstruct
consumer-owned values through the total structural binding. Concrete evaluation, generated
code, symbolic witnesses, binding validation and capability reporting must agree. Unsupported
bindings must fail explicitly rather than acquire an opaque equality translation.

General record/union equality, ordering and arithmetic are outside this request.

## Acceptance

1. A mapped structural enum used both inside a nested record and directly in guarded
   command/register fields checks, scaffolds and compiles with one consumer-owned type.
2. Equal and unequal alternatives exercise both equality operators in concrete execution
   and exact symbolic analysis; every reported model reconstructs a valid owner value.
3. Qualified constructors work; cross-enum and enum/Text comparisons are rejected. Invalid
   or incomplete bindings cannot claim exactness. Existing nominal enum behavior still passes.
4. Generated fingerprints, semantic diff and replay/snapshot qualification expose any
   relevant contract change. Adoption does not silently reinterpret historical events or
   require changing the consumer's established pipeline/diagnostic wire values.
5. Kotei can replace its native-enum bridge after release qualification without blocking
   its current diagnostic implementation or weakening its scope guards.
