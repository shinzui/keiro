---
type: Improvement Request
title: Make reviewed aggregate validation policies first-class in Keiro DSL
description: >-
  Let a checked aggregate declare an exact reviewed allowlist for narrowable Keiki validation
  warnings, and generate matching runtime construction, harness assertions, diff evidence, and
  service conformance without weakening mandatory replay-contract checks.
timestamp: 2026-08-05T04:15:24Z
requestId: IR-17
status: superseded
origin: mori://shinzui/mori
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: 2026-08-04T16:24:05Z
    document_timestamp: 2026-08-04T16:24:05Z
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-5
    effort: unspecified
    context: >-
      Reviewed against Keiro 0.10.0.0 EventStream validation, Language-4 aggregate grammar,
      generated aggregate harnesses, workspace service conformance, and Mori's exact two-warning
      Workflow policy.
---

# Improvement Request: Make Reviewed Aggregate Validation Policies First-Class in Keiro DSL

## Status

Superseded by Keiki 0.9.0.0. Keiki now proves the motivating same-mode integral guards
(`openSteps > 1` and `openSteps == 1`) disjoint even when their conjunctions contain opaque
siblings, so Mori can remove its temporary `checkInversionAmbiguity` override when it adopts that
release. Keiro will not add a first-class reviewed-warning policy for this case.

This decision does not supersede
[`handle-initial-state-replay-only-transitions-in-generated-harnesses.md`](handle-initial-state-replay-only-transitions-in-generated-harnesses.md).
That request concerns the generated layout and conformance treatment of genuine replay-only
edges, not a Keiki validation false positive.

## Supersession Evidence

Keiki implemented `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5` in release
0.9.0.0. Its regression coverage includes the exact `openSteps > 1` versus `openSteps == 1`
comparison with additional opaque identity and stepbook predicates. The improved default
inversion analysis reports no ambiguity for Mori's reviewed pair, so the requested exact
allowlist would preserve a workaround after its cause has disappeared.

Mori's remaining action is dependency adoption: move to Keiki 0.9.0.0 and restore default
validation. That consumer change belongs to Mori and is not an implementation prerequisite for
Keiro's separate replay-only generation fix.

## Context

Keiro core intentionally exposes `validateEventStreamWith` and `mkEventStreamWith` for documented
benign overrides. It always forces the head-recoverability and state-changing-epsilon checks back
on, while permitting callers to narrow non-contract checks such as inversion ambiguity.

Keiro DSL 0.10.0.0 cannot express the same policy. Every generated aggregate harness hardcodes
`validateTransducer defaultValidationOptions transducer == []`, and generated event-stream
construction uses default validation. A consumer that has reviewed a conservative warning must
therefore choose between a red generated service-conformance package, hand-editing generated
files, or assembling a parallel hand-owned runtime stream. None is a reproducible Language-4
contract.

The concrete blocker is
`mori://shinzui/mori/plans/176-rewrite-the-workflow-aggregate-with-real-step-completion-and-causation`.
Mori's runtime narrows only `checkInversionAmbiguity` and separately pins the exact two Workflow
warnings plus every forward/replay closing path. The released generator cannot represent that
review, so MasterPlan 23 cannot close its Workflow prerequisite even though runtime validation
and production replay are green.

## Requested Change

Add a checked aggregate-level validation-policy declaration for an exact allowlist of reviewed
warnings. Exact surface syntax may follow the Language-4 grammar, but the semantic model must
identify each allowed warning by stable structured fields rather than rendered prose—for example
warning kind, source vertex, edge identities, and wire constructor for `InversionAmbiguity`.

The generated contract must:

- run `validateTransducer defaultValidationOptions` and require the actual reviewed-warning set to
  equal the declaration exactly, so added, removed, or retargeted warnings cause conformance
  failure;
- narrow only checks Keiro core documents as caller-narrowable;
- refuse any declaration that disables head recoverability or state-changing epsilon;
- generate event-stream construction with the matching narrowed `ValidationOptions`;
- keep all unrelated default checks enabled;
- expose the reviewed policy in coverage, manifests, scaffold records, service conformance, and
  human-readable diagnostics; and
- classify policy changes in `keiro-dsl diff` as validation/runtime-contract changes even when
  wire, replay, identity, and storage shapes are unchanged.

The declaration is an audited exception, not a generic `validation = off` switch. Scaffolding
must not accept a warning category without exact expected instances, and a stale allowance must
fail when an upstream Keiki release learns to prove the warning absent. Consumers can then remove
the obsolete declaration explicitly.

## Acceptance

1. A fixture with exactly two declared `InversionAmbiguity` warnings compiles, constructs a
   validated event stream with only that check narrowed, and passes its generated aggregate and
   whole-service conformance suites.
2. Adding a third warning, changing either edge identity, or removing one warning fails the exact
   generated assertion with a structured diagnostic.
3. An allowance for head recoverability or state-changing epsilon is rejected during
   `keiro-dsl check`; generated code cannot weaken Keiro's mandatory replay contract.
4. A policy that narrows inversion ambiguity still runs hidden-input, guarded-input-read,
   determinism, reachability, and every other enabled validation check.
5. Single-spec and workspace scaffolding generate the same policy, imports, runtime options,
   harness facts, manifest entries, and scaffold-record entries deterministically.
6. `keiro-dsl diff --explain` reports policy addition, removal, and changed warning identities as
   validation/runtime impact without inventing wire or replay-shape changes.
7. Repeated scaffolding is byte-stable and requires no post-generation patch or hand-maintained
   replacement facade.
8. Authoring and migration documentation explains when a reviewed policy is permitted, why an
   exact allowlist is required, and how to remove it after an analyzer improvement such as
   `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5`.

## Out of Scope

- Silencing arbitrary warnings by rendered message text.
- Making mandatory replay-contract checks caller-disableable.
- Proving the underlying Keiki warning false; producer-side precision is tracked by
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5`.
- Per-deployment runtime flags that can diverge from the checked specification.
- Treating a non-empty unreviewed warning set as successful conformance.

## Compatibility Baseline

The request was verified against Hackage Keiro DSL 0.10.0.0 and the matching public release tags.
`keiro-dsl/src/Keiro/Dsl/Harness.hs` hardcodes the default-empty assertion, while
`keiro-core/src/Keiro/EventStream/Validate.hs` already provides narrowed runtime construction and
forces the mandatory checks on. The requested syntax and generated metadata are additive; specs
without a policy retain the exact current default-empty behavior.

## References

- Requesting initiative:
  `mori://shinzui/mori/masterplans/23-extend-functional-keiki-aggregates-to-every-mori-domain`.
- Reproducer and consumer acceptance:
  `mori://shinzui/mori/plans/176-rewrite-the-workflow-aggregate-with-real-step-completion-and-causation`.
- Keiro DSL package: `mori://shinzui/keiro/packages/keiro-dsl`.
- Keiro core package: `mori://shinzui/keiro/packages/keiro-core`.
- Producer-side precision request:
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5`.
- Implementation surfaces: `keiro-dsl/src/Keiro/Dsl/Harness.hs`,
  `keiro-dsl/src/Keiro/Dsl/ServiceHarness.hs`, aggregate grammar/semantic planning, scaffold
  manifests and records, and `keiro-core/src/Keiro/EventStream/Validate.hs`.
