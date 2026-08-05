# Bundle Update Log

## 2026-08-05
* **Addition**: IR-19 requests honest names for the scaffolder's four generated sidecars — the files
  named `record` are the machine-read ledgers while the file named `manifest` is never parsed — with
  an old-name fallback so a rename cannot silently discard scaffold history, and one durability
  contract so the conformance ledger tolerates unknown rows like the workspace ledger already does.
* **Superseded**: IR-17 will not add reviewed aggregate validation-policy allowlists. Keiki
  0.9.0.0 implements `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-5` and proves
  Mori's motivating `openSteps > 1` / `openSteps == 1` guards disjoint despite opaque sibling
  predicates; Mori can remove its temporary override when it adopts that release.
* **Planning**: IR-18 is planned by
  [Plan 191](../plans/191-unify-generated-transition-layout-for-replay-only-conformance.md), which
  gives generated runtime assembly, predicate verification, behavior attribution, and live
  initial probes one source-wide transition layout with compiled single/workspace conformance.

## 2026-08-04
* **Addition**: IR-18 requires generated harnesses, predicate verification, and behavior
  conformance to treat replay-only transitions from the initial vertex as replay-only, including
  correct cumulative edge indices when one source appears in non-contiguous transition blocks.
* **Addition**: IR-17 requests exact aggregate-level allowlists for reviewed narrowable Keiki
  validation warnings, with matching runtime options, generated harness assertions, diff evidence,
  and service conformance while mandatory replay-contract checks remain non-disableable.
* **Addition**: IR-16 requires a checked naming invariant so Keiro never scaffolds
  non-idiomatic Haskell module or value names from snake_case DSL identifiers, while preserving
  independent wire and SQL spellings.

## 2026-08-01
* **Addition**: IR-15 requests measurement and, if justified, removal of repeated remaining-input
scans during Keiro DSL source-span capture while preserving exact spans and frozen parser
compatibility; it is a parse-time tooling concern, not a generated-service runtime blocker.
* **Implemented**: Close IR-12 after Plan 170 adds declaration-scoped ID and enum equality, exact consumer KindID and finite-enum domains, conservative legacy generated-ID verification, type-confusion diagnostics, replay/workspace conformance, and mutation evidence.
* **Implemented**: Close IR-11 after Plan 167 recognizes preambles only before `context`, moves
released feature markers to their owning grammar productions, preserves version-1 diagnostics,
and passes library, CLI, scaffold, workspace, full-suite, all-package, and Nix validation.
* **Implemented**: Close IR-13 after Plan 159 makes total `fields(Command)` event outputs
generated-owned, removes identity-copy Holes from runtime authority, and proves the boundary with
compiled single-spec/workspace conformance and restoring mutations.
* **Implemented**: Close IR-2 after Plan 168 gives shared generated IDs and enums one context-level Haskell owner with cross-aggregate compile, deterministic planning, and non-destructive 0.6 adoption evidence.
* **Dependency baseline**: Keiki public `master` implements
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`,
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3`, and
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4`, and the local release tree packages
them as `0.7.0.0`. Keiro IR-12, IR-13, and IR-14 and their plans now treat that API as the
development baseline, so work can start without waiting on more producer implementation. Keiro
may also adopt `>=0.7 && <0.8`: Hackage now publishes `0.7.0.0`, and `v0.7.0.0` resolves to
release commit `7c5d433ef4455e9e626347f89cb3a416bad62e72` with the required APIs.
* **Planning**: IR-11 is planned by Plan 167 under MasterPlan 27, covering grammar-positioned
preambles, parsed feature gates, lexical collision regressions, and released-version parity.
* **Planning**: reopened IR-2 is planned by Plan 168 under MasterPlan 27, giving every shared
generated nominal declaration one Haskell owner and adding a compiled two-aggregate proof.
* **Planning**: IR-12 is planned by Plan 170 under MasterPlan 27 and targets the Keiki `0.7.0.0`
implementations of `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-3` and
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-4` for conservative projection
exactness and exact domain-constrained reconstructible witnesses.
* **Planning**: IR-13 reuses and updates unfinished Plan 159 under MasterPlan 27 instead of creating
a duplicate output/conformance plan.
* **Planning**: IR-14 is planned by Plan 171 under MasterPlan 27, with Plan 169 supplying the
effective semantic language contract required for versioned enforcement and legacy replay.

## 2026-07-31
* **Review finding**: IR-2 remains incomplete in Keiro 0.6.0.0 because workspace scaffolding emits
separate nominal Haskell declarations for one shared logical `ProjectId` in each aggregate
module; its status now records this release-blocking acceptance failure.
* **Addition**: IR-14 requests a versioned, enforceable runtime contract for declared ID prefixes
without silently breaking persisted legacy events.
* **Addition**: IR-13 requests generated-owned event output mappings when `fields(Command)` already
specifies a total identity copy.
* **Addition**: IR-12 requests type-safe equality for generated and consumer-bound nominal IDs and
enums in aggregate expressions.
* **Addition**: IR-11 requests grammar-aware language-preamble and feature detection after Keiro
0.6.0.0 misclassified Mori's nested `language` field as a file preamble.
* **Review and planning**: IR-3 was revalidated against the current outbox implementation and is
linked to plan 165 for its public outcome, durable rejected status,
ordering, crash/recovery, telemetry, migration, and compatibility implementation.
* **Addition**: IR-10 requests an optional atomic async-projection mode whose user SQL, fencing,
and Kiroku checkpoint advancement commit together through released store/adapter APIs.
* **Addition**: IR-9 requests a bounded declarative dynamic-router selection language while
retaining effectful resolver holes as an explicit unchecked escape hatch.
* **Addition**: IR-8 requests first-class atomic multi-stream command coordination above Kiroku's
lower-level transaction substrate.
* **Addition**: IR-7 requests typed application rejection and no-op outcomes instead of reducing
every business refusal to generic `CommandRejected`.
* **Addition**: IR-6 requests independent DSL, generated Haskell-selector, and JSON wire-key names
for direct aggregate fields.
* **Addition**: IR-5 requests sequential version-aware `keiro-dsl upgrade` transforms and later
Mori-aware fleet rewrite planning after the declared-language-version foundation lands.
* **Review**: IR-4 passes an in-repository technical-accuracy review against the current Keiro
implementation and the released Keiki `Natural` capability. The review corrected the
description of Haskell `Natural` subtraction from saturation to `Underflow` and records that
the required capability is published in Keiki `0.5.0.0` on Hackage with a matching upstream tag.
* **Addition**: IR-4 requests truthful direct aggregate lowering for `Time` and `Natural`, plus a
shared validation/scaffolding capability model so a clean check cannot fail later on type
lowering.

## 2026-07-30
* **Addition**: IR-3 requests an explicit terminal outbox rejection outcome so downstream
applications can finalize intentional refusals without retrying or reporting success.

## 2026-07-29
* **Addition**: IR-2 requests first-class multi-file service composition for per-aggregate Keiro specs, including shared declaration resolution, whole-service validation/diffing, and atomic context-level scaffolding.

## 2026-07-28
* **Review**: IR-1 records an OpenAI Codex review with gpt-5.6-sol at xhigh effort after
in-repository verification against Keiki constraints and Keiro architecture principles.
* **Addition**: IR-1 requests structural consumer-owned record and union support in keiro-dsl for Mori EP-171.
