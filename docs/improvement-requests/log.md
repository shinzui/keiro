# Bundle Update Log

## 2026-08-21
* **Addition**: IR-33 requests idempotent, semantically exact aggregate guard diffing after the
  published `keiro-dsl` 0.14.0.0 binary reported 39 `AggGuardTightened` advisories for Mori's
  byte-identical Language-5 workspace while simultaneously declaring the diff replay-neutral.
  The request preserves the replay-only remedy for genuine tightenings, but requires a real,
  satisfiable removed region before Keiro prints that remedy.

## 2026-08-19
* **Addition**: IR-26..IR-32 filed by the keiro runtime UI initiative (origin mori://shinzui/keiro-ui): serve the keiro-ops surface over HTTP, WebSocket live feeds over Keiro.Wake, aggregate inspection reads, process-manager inspection reads, workflow inspection primitives for HTTP, composed runtime surface mounting, and recording the inspection-UI boundary in an ADR.

## 2026-08-12
* **Implemented**: MasterPlan 38 completes IR-23 and IR-24. Candidate Language 5 now derives
query supply from target ownership, puts `delivery` only on projection owners and `freshness`
only on query models, generates truthful cursor-aware runtime builders, and distinguishes the
two policies in diagnostics, identity, diff, ledger, workspace, and compiled conformance facts.
Languages 1–4 remain frozen; the runtime compatibility names remain deprecated through 0.12.
* **Planning**: IR-23 and IR-24 are release-gating work under
[MasterPlan 38](../masterplans/38-finalize-projection-ownership-and-query-freshness-before-stable-language-5.md).
[Plan 243](../plans/243-make-projection-owners-authoritative-for-catalog-bound-query-models.md)
makes target ownership authoritative for query supply;
[Plan 244](../plans/244-introduce-truthful-query-freshness-runtime-apis-with-compatibility.md)
adds the runtime compatibility layer and canonical identity revision; and
[Plan 245](../plans/245-separate-language-5-projection-delivery-from-query-freshness.md)
finalizes the Language 5 surface. Completed MasterPlan 36 remains closed. IR-25 is intentionally
deferred beyond 0.12 because it expands generated aggregate behavior rather than repairing this
projection contract.
* **Addition**: IR-25 requests total typed field mappings at Language 5 aggregate emit sites,
including deterministic derived values, mapped constructors, and conditional field expressions.
It preserves Keiki's static per-edge event vector and hidden-input replay invariant: conditional
event presence remains disjoint guarded edges, and a derived field cannot be the only carrier of
a command input. Raised by `mori://tan/notification-render-service`; generalizes IR-13 without
reopening the separate collection-register gate in Plan 166.
* **Addition**: IR-24 separates projection delivery from query freshness. Language 5 catalog
projection owners become the sole source of inline/subscription delivery, while query models use
truthful immediate/head-wait/position-wait terminology instead of the confusing
`feed = inline` plus `consistency = Eventual` combination. It preserves Languages 1–4 and requires
a compatibility path for the released `ConsistencyMode` API. Raised by
`mori://tan/notification-render-service`; depends conceptually on IR-23's authoritative owner/query
relationship but remains a separate runtime and language migration.
* **Addition**: IR-23 requests that Language 5 let one catalogued inline projection owner supply
several separately typed query models over its targets. It replaces the misleading requirement
that every inline model be named by the aggregate's single standalone `projection` clause, while
preserving Languages 1–4 and keeping the broader `feed`/`consistency` vocabulary redesign separate.
Raised by `mori://tan/notification-render-service`, whose boot-time Catalog activation must update
three validation targets atomically without collapsing independent queries into one tagged union.

## 2026-08-11
* **Runtime closeout**: Plan 231 completes IR-7's handwritten runtime latency,
allocation, one-dispatch residency, committed command baseline, and shared
regression evidence. Keep IR-7 proposed only for Plan 232's independent
committed DSL generation baseline and `bench-regression` wiring.

## 2026-08-10
* **Implemented**: Close IR-9 after Plan 230 delivers checked bounded Language 5 router selection, generated runtime integration, stable-union PostgreSQL conformance, coordination-impact reporting, durable selection metadata, and the custom-unverified fallback.
* **Addition**: IR-22 requests that read models become safely readable by out-of-process
consumers — a fence a database-level reader observes, documented projection status metadata,
zero-downtime versioned rebuild with atomic cutover, and targeted per-stream reprojection.
Raised by `mori://tan/notification-render-service`, whose TypeScript render process reads live
published content over SQL and therefore participates in none of the in-process fence checks in
`runQuery`, `runCommandWithCatalogProjections`, or `applyAsyncProjectionFromCatalog`. Extends
IR-20 to a reader class its offline in-place rebuild did not have to consider.
* **Runtime**: Plan 231 delivers the additive handwritten runtime contract across direct, SQL, projection, router, process-manager, retry, and bounded telemetry paths; keep IR-7 proposed until Plan 232 completes DSL generation and quiet-host performance evidence is recorded.
* **Implemented**: Close IR-15 after Plan 229 benchmarked and removed repeated suffix scans while
preserving exact spans and parser compatibility.
* **Completed**: Close IR-21 after MasterPlan 34 and Plan 222 deliver checked semantic locality, stable behavior source maps, impact reporting, restoring mutations, the pinned Mori replay, and a byte-clean corpus; migrate legacy implemented statuses to the current completed vocabulary.

## 2026-08-09
* **Review**: Correct IR-21 technical scope to current command, private-event, and register roots
and separate service-owned declaration laws from aggregate-use evidence.
* **Addition**: IR-21 requests semantically local workspace regeneration and stable behavior
source anchors so a mapped-shape change rewrites only reachable aggregate outputs while
whole-service conformance and current source-located diagnostics remain complete.
* **Implemented**: Reconciled IR-20 after [MasterPlan 32](../masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md)
and all five child plans completed; follow-up
[MasterPlan 33](../masterplans/33-make-subscription-checkpoint-lifecycle-explicit-before-the-next-release.md)
extends missing-checkpoint lifecycle semantics without reopening the typed catalog request.
* **Implemented**: Reconciled IR-16 from
[Plan 190](../plans/190-guarantee-idiomatic-haskell-names-for-generated-declarations.md)'s
completed checked Haskell naming, migration, conformance, and documentation evidence.
* **Implemented**: Reconciled IR-4 from
[Plan 157](../plans/157-unify-aggregate-type-capabilities-and-lower-time-and-natural.md)'s
completed aggregate Time/Natural lowering, conformance, and repository validation evidence.
* **Implemented**: Reconciled IR-1 after
[MasterPlan 25](../masterplans/25-structural-consumer-type-ergonomics-and-soundness-preserving-adoption-for-keiro-dsl.md)
delivered and released the structural/opaque consumer-owned type contract, and Mori recorded the
upstream prerequisite as already satisfied.

## 2026-08-08
* **Acceptance and planning**: IR-20 requests one typed runtime catalog for projection ownership,
physical read-model targets, registration, and rebuild adapters, with structural
missing/duplicate-owner validation and explicit brownfield-safe reconcile policy. MasterPlan 32
and plans 209–213 define the implementation; Kiroku IR-1 is a non-blocking bounded-read companion.

## 2026-08-05
* **Implemented**: Close IR-19 after Plan 198 ships role-bearing sidecar names, explicit lossless migration, and a forward-compatible conformance ledger.
* **Implemented**: Close IR-18 after Plan 191 unifies source-wide transition identity and proves replay-only initial conformance across single, workspace, and generated service paths.
* **Planning**: IR-19 is revised and planned by
[Plan 198](../plans/198-rename-keiro-dsl-sidecars-to-explicit-slot-ledger-names-with-one-durability-contract.md)
under MasterPlan 29. The planning review kept the diagnosis and changed the solution: the
machine-owned stem is `ledger` rather than `lock` (lockfiles are regenerable; these files are
not), the workspace/context slots are explicit literal segments so collision-freedom needs no
proof, the conformance ledger keeps its qualifier, and migration rides the refuse-then-apply
`--apply-name-migrations` rail as lossless file moves instead of silently falling back to old
names and marking them superseded.
* **Implemented**: Close IR-6 after Plan 192 separates DSL, generated-selector, and wire-key identities across aggregate and contract fields with compiled conformance and diff/replay evidence.
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
non-idiomatic Haskell module or value names from snake\_case DSL identifiers, while preserving
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
