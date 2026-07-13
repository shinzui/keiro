---
id: 15
slug: harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit
title: "Harden and extend the keiro-dsl toolchain surfaced by the 2026-07 DSL audit"
kind: master-plan
created_at: 2026-07-13T18:56:47Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
---

# Harden and extend the keiro-dsl toolchain surfaced by the 2026-07 DSL audit

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

In July 2026, after MasterPlan 14's runtime hardening was underway, a full audit of the
`keiro-dsl` package (built by MasterPlan 8 in June 2026 and untouched by MasterPlans
9–14, which all declared it out of scope) examined the toolchain's three gates —
`check`, `diff`, `scaffold` — and its fidelity to the current keiro architecture. The
audit confirmed the foundations are right (the generated/hole overwrite discipline is
safe for repeated agent regeneration, the emitted runtime API surface compiles green
against post-MP-14 keiro across all sixteen conformance suites, and the firewall and
conformance-suite mechanisms are the correct architecture) and surfaced defects in two
themes. First, the gates over-promise: the differ is blind to field-type, enum, wire,
contract, and identity-bearing changes (several confirmed exit-0 on breaking edits);
the validator has verified holes one hop away from its fixtures (workflows and rule
bodies receive zero validation, process dispatch commands are never resolved,
disposition tables are defeatable by omission or duplicate rows, duplicate node names
scaffold silent clobbers); and the notation itself can silently change meaning (no
string escaping in either direction, first-wins duplicate clauses, a load-bearing
`mapPartial` flag with no syntax). Second, the spec surface still reflects June's
keiro: everything MasterPlans 9–14 made into a forced authoring decision — read-model
registration and schema, rejected-command and poison policies, the router primitive,
pgmq ordering and provisioning, snapshot policy, workflow patch/continue-as-new, the
safe category-stream API — is unexpressible, and in two confirmed cases the generated
output now contradicts the runtime (a spec-level `deadLetter` disposition that the
runtime's default `RejectedHalt` turns into a subscription halt; `Strong` consistency
offered for inline-only projections whose cursor never advances).

When this initiative is complete: `keiro-dsl diff --since` is a sound merge gate — every
decode-relevant or identity-bearing change in ANY node family classifies Breaking or is
explicitly documented as out of diff scope, never silently additive; `keiro-dsl check`
rejects the audited dangerous-spec shapes (duplicate workflow labels, clock reads hidden
in rules, unresolved dispatch commands, shadowed disposition rows, wrong-topic
couplings, colliding names) with line-numbered diagnostics; a spec that passes `check`
scaffolds code that compiles (identifier hygiene, non-empty node rules, faithful
backoff/duration lowering) and cannot inject tokens past the firewall (escaped splices,
a canonical operator list derived from keiki's actual exports); the spec surface again
covers keiro's forced decisions (a first-class `readmodel` node with registration and
schema, a `router` node, `rejected`/`poison` policy clauses lowered to real
`WorkerOptions`, pgmq ordering/provisioning clauses, aggregate snapshot policy,
workflow `patch`/`continueAsNew`, category-based stream construction); and the
authoring skill, notation reference, and corpus teach the new surface truthfully,
proven by a fresh cold-start service exercising it end to end.

Standing assumption (user directive, 2026-07-13): MasterPlan 14
(`docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md`)
is implemented BEFORE this initiative. Every child plan may rely on its outputs — the
`CommandAmbiguous` taxonomy (EP-95), `RejectedCommandPolicy`/`PoisonPolicy`/
`WorkerOptions` and durable dispatch dead letters (EP-100), stable router idempotency
keys and `confirmBenignDuplicate` (EP-97), snapshot guards (EP-98), and the read-model
rebuild and `Strong` cursor semantics (EP-101) — and must NOT plan changes to them.

In scope: the `keiro-dsl` package (library, CLI, unit and conformance tests), the
authoring skill under `agents/skills/keiro-dsl-authoring/`, and the corpus index under
`docs/corpus/`. Out of scope: any change to `keiro`, `keiro-core`, `keiro-pgmq`, keiki,
or kiroku (this initiative only consumes their exported surfaces); the
delegated-idempotence intake mode (its runtime has not landed —
`docs/plans/83-delegated-idempotence-inbox-intake-bypass-the-keiro-inbox-table-when-the-downstream-state-machine-already-dedupes.md`
already scopes its own DSL surface and must not be duplicated here); sharding and
consumer-group worker configuration (deployment-scoped, hole-kind 8 per MasterPlan 8's
boundary); and the jitsurei example repos (outdated, per the standing MP-14 directive).
The audit's "do not fix" list is binding: the overwrite/hole discipline, the emitted
runtime API names, and the conformance-suite architecture are sound and must be
strengthened, not replaced.


## Decomposition Strategy

The audit's findings cluster into four phases by theme and blast radius, mirroring how
the toolchain is trusted in the authoring loop: first make the gates tell the truth,
then make the generator safe under unattended regeneration, then widen the spec surface
to the post-MP-14 architecture, then re-teach the loop.

Phase 1 makes the three gates sound, one plan per gate because each has its own
machinery and test apparatus: EP-103 rebuilds the differ around an explicit per-node
registry (the audit's worst area — several confirmed breaking-change classes exit 0
today); EP-104 closes the validator's soundness holes (the product's core value is
rejecting dangerous specs before Haskell exists, and the audit showed the promise holds
only for the exact fixture shapes); EP-105 fixes notation integrity in the
parser/pretty-printer pair (string escaping is the single worst defect — a confirmed
silent meaning change — plus duplicate-clause first-wins, numeric wraparound, and
identifier legality).

Phase 2 is EP-106, the scaffolder: the one unescaped splice (template injection into a
`-- @generated` module), the firewall's incomplete and self-inconsistent operator list,
silent path collisions and stale-module lingering, certified-valid skeletons that emit
uncompilable code, and silently corrupted policies (backoff kinds coerced, duration
units dropped). It is grouped as its own phase for review focus, not blocking — it can
start immediately.

Phase 3 restores the bijection with three node-surface plans, split by primitive
cluster exactly as MasterPlan 8's verticals were: EP-107 (the `readmodel` node plus the
DB-schema clause — the one gap that makes generated bootstrap code fail at runtime),
EP-108 (the `router` node plus the `rejected`/`poison` policy surfaces on both
coordination nodes — the gap where the spec contradicts the runtime), and EP-109 (the
remaining coverage: pgmq ordering/provisioning, aggregate snapshot policy, workflow
patch/continue-as-new, plus the recorded scope decisions on intake persistence modes and
sharding). Each follows MP-8's per-vertical discipline: grammar, parser, printer,
generator arm, validator rules, differ registration, scaffold, harness, live-runtime
conformance suite.

Phase 4 is EP-110, the delivery tail: category-stream notation (the one place the
notation itself codifies a superseded unsafe idiom), `confirmBenignDuplicate` and the
ambiguity/epsilon guidance in the skill, truthing-up NOTATION.md's "Checked:" claims,
the corpus refresh, and a cold-start proof on the new surface — the initiative's
end-to-end acceptance.

Alternatives considered: one giant "gates" plan (rejected: differ, validator, and
parser have disjoint machinery, tests, and reviewers; three plans maximize parallelism
with only a diagnostic-code integration point); folding the policy surfaces (EP-108)
into the process-node fixes in EP-104 (rejected: EP-104 is mechanical
soundness-restoration with red/green fixtures, EP-108 is notation design work with a
new conformance suite — the same split MP-14 used for EP-97 vs EP-100); per-finding
micro-plans (rejected: ~40 findings would produce unreviewable fragmentation; the audit
already groups them by the module whose contract they break); and fixing the gates
inside each Phase 3 vertical (rejected: the verticals must extend sound machinery, not
carry unrelated soundness fixes — the differ registry in particular must exist before
three plans register with it).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 103 | Make keiro-dsl diff sound over the full decode and identity surface | docs/plans/103-make-keiro-dsl-diff-sound-over-the-full-decode-and-identity-surface.md | None | None | Complete |
| 104 | Close the keiro-dsl validator soundness holes: workflows, rules, cross-node references, and disposition tables | docs/plans/104-close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables.md | None | None | Complete |
| 105 | Fix keiro-dsl notation integrity: string escaping, duplicate clauses, numeric bounds, and identifier hygiene | docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md | None | None | Complete |
| 106 | Harden the keiro-dsl scaffolder: template injection, firewall completeness, collision and stale-module detection, and faithful policy lowering | docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md | None | EP-104, EP-105 | Complete |
| 107 | Add a first-class read-model node with registration, schema, and consistency to keiro-dsl | docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md | EP-103 | EP-104, EP-105, EP-106 | Complete |
| 108 | Add a router node and rejection and poison policy surfaces to keiro-dsl | docs/plans/108-add-a-router-node-and-rejection-and-poison-policy-surfaces-to-keiro-dsl.md | EP-103 | EP-104, EP-105, EP-106 | Complete |
| 109 | Extend keiro-dsl node coverage: pgmq ordering and provisioning, snapshot policy, and workflow patch and continue-as-new | docs/plans/109-extend-keiro-dsl-node-coverage-pgmq-ordering-and-provisioning-snapshot-policy-and-workflow-patch-and-continue-as-new.md | EP-103 | EP-104, EP-105, EP-106 | Not Started |
| 110 | Align keiro-dsl with the safe APIs and refresh the authoring skill and corpus | docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md | EP-107, EP-108, EP-109 | EP-103, EP-104, EP-105, EP-106 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-103).


## Dependency Graph

EP-103, EP-104, EP-105, and EP-106 can all start immediately and in parallel — they
harden four different modules (`Keiro.Dsl.Diff`, `Keiro.Dsl.Validate`,
`Keiro.Dsl.Parser`/`PrettyPrint`, `Keiro.Dsl.Scaffold` plus the CLI) whose only contact
is through the integration points below (diagnostic codes, the escape contract, and
status-map matching semantics), each of which is a documented reconciliation, not a
code dependency. EP-106's soft dependencies on EP-104 and EP-105 exist because two of
its fixes read better landing after (or coordinated with) their counterparts: the
escape contract EP-105 defines is what EP-106's splice fix implements, and the
non-empty-aggregate rule may live in the validator EP-104 owns; neither blocks EP-106's
injection, firewall, collision, or lowering milestones.

EP-107, EP-108, and EP-109 hard-depend on EP-103 because each registers a new node
family (or newly evolution-relevant clauses) with the generalized differ machinery
EP-103 introduces — without it they would each re-create ad hoc diff arms in the very
module EP-103 is restructuring, and EP-109's patch-aware workflow classification
refines classification hooks that only exist post-103. Their soft dependencies on
EP-104/EP-105/EP-106 express that new grammar constructs should be validated, escaped,
and scaffolded through the hardened machinery (a vertical landing first must extend the
old machinery and rebase its rules when the gate plans land — possible, but the
reviewable order is gates first). The three verticals are mutually independent and can
run in parallel; their shared touch points (the `Node` sum type, the diagnostic-code
enum, the differ registry) are additive edits coordinated through Integration Points 1–3.

EP-110 hard-depends on EP-107, EP-108, and EP-109 because it documents and cold-start-
proves their surfaces; its category-stream notation change and reference-fill rewrites
are independent of them but are deliberately batched into the delivery tail so the
skill refresh happens once, against the final notation.

Critical path: EP-103 → (EP-107 ∥ EP-108 ∥ EP-109) → EP-110, with EP-104, EP-105, and
EP-106 in parallel alongside the front of that path.


## Integration Points

1. **The `Keiro.Dsl.Grammar` AST and the faithfulness contract (all plans).** MP-8's
   rule stands: a construct exists only if its parser, pretty-printer, round-trip
   generator arm, validator rules, and scaffold cases land in the same change — and this
   initiative extends the contract with differ coverage (a new construct must register
   its decode/identity surface with EP-103's machinery or be explicitly classified out
   of diff scope in code). EP-104 additionally adds per-row `Loc` fields to existing
   grammar types (`StateDecl`, `DispositionRow`, `DispatchNode`, `WqDispRow`) for
   diagnostic anchoring — `Loc`'s `Eq` ignores line numbers, so round-trip properties
   are unaffected. EP-107 adds `NReadModel`, EP-108 adds `NRouter` plus policy fields on
   `ProcessNode`, EP-109 adds `WorkqueueNode` fields, an aggregate snapshot clause, and
   `WfBodyItem` constructors. EP-110 reshapes `SagaRef` for category streams.

2. **The `DiagnosticCode` registry in `Keiro.Dsl.Validate` (EP-103, EP-104, EP-107,
   EP-108, EP-109).** EP-104 owns the registry discipline and enumerates its new codes
   in one place; EP-103 adds the corrected diff codes (field removal and version
   decrease stop reusing `EvtFieldAddedWithoutBump`); the Phase 3 verticals append
   node-specific codes. No plan renames another plan's codes — tests match on codes.

3. **The generalized differ machinery (EP-103 defines; EP-107, EP-108, EP-109
   register).** EP-103 restructures `Keiro.Dsl.Diff` into per-node-family diffing with
   an explicit registry in which every `Node` constructor is either diffed or
   explicitly classified out of scope with written rationale. EP-107 registers the
   read-model identity surface (version, table, schema, subscription), EP-108 the
   router's (its stable name is identity-bearing — renaming re-dispatches everything),
   EP-109 the workqueue/snapshot/workflow-evolution surfaces including patch-guarded
   classification (a workflow body change guarded by a new `patch` item is safe; an
   unguarded reorder is breaking). The three verticals were authored against EP-103's
   stated interface expectations; whichever implements after EP-103 reconciles against
   the delivered shape.

4. **The string-escape contract (EP-105 defines, EP-106 applies).** EP-105 owns the
   notation-level semantics (escaping in `stringLit`/`dquoted`, its round-trip proof);
   EP-106 fixes the one raw splice (`payloadExpr` in `Keiro.Dsl.Scaffold`) using the
   same semantics. Both plans state the contract identically and can land in either
   order.

5. **Status-map matching semantics (EP-104 and EP-106, lockstep).** Both the validator
   totality check and the scaffold lowering move from suffix matching to EXACT
   event-name matching, with dangling-key and ambiguity diagnostics. Whichever plan
   lands second verifies against the other's fixtures; the semantics must never
   diverge again (that divergence is how `ReservationUnHeld` silently lowered to the
   `Held` status).

6. **The firewall's canonical operator list (EP-106 defines; EP-107, EP-108, EP-109
   satisfy).** EP-106 derives one list from keiki's actual exported symbolic-operator
   surface, used by both the CLI scan and the unit test (today they disagree). Every
   Phase 3 vertical's emitters must pass the strengthened scan; aeson's `.=` stays
   allowed by design.

7. **Policy lowering and the disposition vocabulary (EP-108 defines; EP-110
   documents).** EP-108 owns the generated `WorkerOptions` artifact for both `process`
   and `router`, the consistency rule between node-level `rejected`/`poison` clauses
   and per-dispatch arms, and the decision on an explicit ambiguity arm
   (`CommandAmbiguous` handling). EP-110's skill guidance must teach exactly the
   vocabulary EP-108 delivers. EP-106's "faithful policy lowering" (backoff kinds,
   duration units) is the same principle applied to existing clauses — distinct scope,
   no shared code.

8. **Read-model reference resolution (EP-104 stubs, EP-107 completes).** EP-104
   validates `CommandOp` fully but explicitly stubs `QueryOp` and the
   `PgmqDispatch` read-model references pending a declarable read-model node; EP-107
   completes both resolutions against its `readmodel` node. The stub must be a
   documented deferral (a code comment naming EP-107's plan path), never a silent pass.

9. **Validator-vs-scaffold rule placement for empty nodes and unsupported registers
   (EP-104 and EP-106, reconcile at implementation).** Both plans state a preferred
   owner for "an aggregate must declare at least one command, event, and transition"
   and "unsupported register types are rejected, Text initials are escaped"; whichever
   implements first takes ownership and the other verifies. The non-negotiable outcome:
   every `keiro-dsl new <kind>` skeleton passes `check` AND scaffolds compiling code.

10. **NOTATION.md and the skill (all plans; EP-110 owns the whole).** Each plan makes
    minimal truthful updates for its own surface (EP-104 fixes the two claims the audit
    proved false — the workqueue-trio check and the child-id check); EP-110 performs the
    holistic SKILL/NOTATION/LOOP/WALKTHROUGH/corpus refresh and re-audits every
    "Checked:" claim against the delivered validator, then proves the loop with a
    cold-start service on the new surface.

11. **Shared fixtures and the scaffold-conformance pins (EP-104, EP-105, EP-106,
    EP-107, EP-108, EP-110).** Five plans rewrite the committed `.keiro` fixtures and
    regenerate the pinned `Generated.*` conformance modules: EP-104 forces the
    hospital-surge fixtures and the process skeleton to declare their dispatched
    commands, EP-106 rewrites status-map keys to full event names (the canonical
    fixtures themselves use suffix keys today), EP-107 updates
    `reservation-work.keiro`/`subscription.keiro` for its new rules, EP-108's mandatory
    `rejected`/`poison`/`on-ambiguous` arms touch every process fixture, and EP-110's
    category-stream migration regenerates every pinned Generated tree (and renames the
    SurgeDemo stream family to a legal category spelling). Each plan re-pins only the
    fixtures it changes and re-runs the full conformance battery before completing;
    when two of these plans are in flight simultaneously, the later-merging one rebases
    its fixture edits.


## Progress

- [x] EP-103: every node family diffed or explicitly out-of-scope; field-type, enum, wire, and contract changes classify Breaking with red/green fixtures
- [x] EP-103: version-chain contiguity checked against the old spec; identity-bearing renames (workflow stable name, id prefixes) Breaking; corrected diagnostic codes
- [x] EP-104: workflows and rules validated (duplicate labels rejected, rule-body clock/scope bypass closed, rule totality)
- [x] EP-104: process/operation cross-refs resolved; disposition completeness and duplicate-row shadowing; topic affinity; duplicate-name rules; workqueue fixture trio fully checked
- [x] EP-105: string escaping round-trips adversarial input; mapPartial has concrete syntax; duplicate wire/projection/goto rejected
- [x] EP-105: numeric bounds enforced; identifier-hygiene diagnostics; round-trip generator covers all node families; unit suite cwd-independent
- [x] EP-106: payload splice escaped (injection closed); canonical firewall list shared by CLI and test with token-aware scan; breach handling is pre-write refusal
- [x] EP-106: path-collision/stale-module/banner detection; every `new` skeleton scaffolds compiling code; backoff and duration lowering faithful; harness handles Int; conformance pin includes imports
- [x] EP-107: `readmodel` node parses, validates, round-trips; Strong-on-inline-only impossible; schema clause threads into projection holes
- [x] EP-107: scaffold emits ReadModel value + registration; QueryOp and PgmqDispatch read-model resolution completed; conformance against live Keiro.ReadModel
- [x] EP-108: `router` node full vertical with conformance against live Keiro.Router
- [x] EP-108: `rejected`/`poison` clauses on process and router lowered to WorkerOptions; per-dispatch consistency rule; ambiguity vocabulary decided and pinned
- [ ] EP-109: workqueue ordering/provision/group clauses lowered against live keiro-pgmq (unlogged warned)
- [ ] EP-109: aggregate snapshot policy clause lowered and accepted by mkEventStreamOrThrow; workflow patch/continueAsNew with patch-aware diff classification
- [ ] EP-110: category-stream notation replaces raw concatenation in grammar, scaffold, and reference fills; confirmBenignDuplicate woven into fills and hole guidance
- [ ] EP-110: skill/NOTATION/corpus refreshed and truthful; cold-start proof on the new surface green


## Surprises & Discoveries

- The audit found the emitted runtime API surface in good sync with post-MP-14 keiro
  (all sixteen conformance suites compile and pass) — the drift is coverage drift,
  not bit-rot. The conformance-suite architecture is why; the plans strengthen it (the
  pin's import-stripping hole, EP-106) rather than replace it.
- Two documented features turned out to be unimplemented stubs rather than weak
  implementations: `enumRemovedFromFields` in `Keiro.Dsl.Diff` returns `[]` under a
  docstring claiming the rule, and `mapPartial` is consulted by the validator but has
  no concrete syntax. Plans treat "docstring claims it, code doesn't do it" findings as
  the highest-priority class after silent meaning changes.
- The duplicate-aggregate clobber is worse than a plain overwrite: the second node's
  generated modules win while the FIRST node's hole stub is kept (create-if-absent), so
  the scaffold output is internally inconsistent with no diagnostic.
- Plan authoring (2026-07-13) surfaced discoveries that sharpened the plans:
  - EP-110 found `sagaStreamPrefix` is lowered NOWHERE today — the canonical spec says
    `"hospital-surge-"` while the reference fill uses `"surge-"` and nothing catches the
    drift; this strengthens the category-clause redesign from a nice-to-have into the
    fix for a live silent divergence. It also found the audit's example category names
    are themselves illegal under the runtime's `category` rule (hyphens collide with
    the stream-name separator), so fixtures adopt camelCase spellings.
  - EP-107 found the aggregate projection clause's `consistency=` value is never
    lowered by the scaffold at all (the Strong-on-inline hazard is purely notational
    today), and that the in-flight EP-101 runtime `ReadModel` record has grown a ninth
    field (`strongScope`) beyond the audit's summary — plans quote the nine-field
    record.
  - EP-104 found the existing workqueue physical-name check implements a DIFFERENT
    sanitization algorithm than the runtime's `queueRef`, so it can also false-positive
    — the trio fix corrects the algorithm, not just the coverage, and pins it against
    the live derivation in the conformance-queue-runtime suite.
  - EP-105 found the audited "six" `L.decimal` sites were seven, and a second raw-text
    storage quirk (`pBindingValue` stores quoted binding literals quote-wrapped), both
    now in its scope with repros.
  - EP-109 corrected an authoring premise: workflows DO get generated modules via the
    CLI (`harnessWorkflow` emits WorkflowFacts.hs and WorkflowRuntime.hs); its
    extensions build on those rather than inventing a workflow scaffold.
  - EP-108 resolved the ambiguity-vocabulary question (Integration Point 7) at
    authoring time: an explicit, grammar-mandatory `on-ambiguous` arm at the timer
    level and documented rejection-class lumping (matching `isRejectionClass`) at the
    dispatch level — a deliberate breaking notation change so existing process specs
    fail parse rather than inherit the silent-halt default. EP-110's skill guidance
    depends on exactly this vocabulary.
  - EP-103 implementation found that a pgmq dispatch retarget and a dedupe-queue change
    cannot share one warning fixture: changing `enqueue to` is `DispatchRetargeted`
    (WARNING), but changing `seenIn queue` is independently `DedupeIdentityChanged`
    (BREAKING). The committed retarget fixture adds a second valid workqueue while
    retaining the original dedupe arm, so plans extending dispatch/workqueue notation
    must preserve this separation.
  - EP-104 implementation landed exact, case-sensitive full-event-name status-map
    validation and converted every committed fixture key without changing generated
    conformance output. EP-106 now has a concrete delivered validator behavior to mirror
    in scaffold lowering; suffix matching remains only on that not-yet-implemented side.
  - EP-104's pure `derivedQueueTrio` matched the live `keiro-pgmq` `queueRef` over all
    six edge-case vectors, including the drafted long-name hash. The read-model
    resolution seam also landed as the documented no-op stub for EP-107 to complete;
    QueryOp and read-model-backed pgmq dispatch references remain intentionally deferred.
  - EP-104's full-package run corrected the audit's suite count: the package has 16
    `keiro-dsl-conformance-*` suites plus the unit suite, 17 test suites total. All 17
    passed; later plans should use the package target rather than a hand-maintained
    numeric list.
  - EP-105 implementation found the built-in aggregate skeleton itself had a generated
    constructor collision: state `Done` and event `ThingDone` both scaffolded as
    `ThingDone`. EP-105 renamed the starter event to `ThingCompleted`; EP-106 can rely on
    `new aggregate` passing the identifier-hygiene gate before its compile-all-skeletons
    milestone.
  - EP-105's all-family round-trip generator found that top-level node keywords are a
    load-bearing parser registry: omitted `process`/`dispatch` entries made a preceding
    aggregate consume them as transition sources, and `emit Name {` needed brace
    lookahead to distinguish it from a transition emit clause. EP-107/108/109 must add
    every new top-level keyword (`readmodel`, `router`, or otherwise) to `reservedWords`
    in the same vertical that adds its parser arm.
  - EP-106 implementation found five legitimate `Keiki.Core` names in the generated
    deterministic layer (`RegFile`, `HsPred`, `defaultValidationOptions`, `step`, and
    `validateTransducer`) that the authored firewall sketch omitted. The delivered import
    guard allows only those explicit names and rejects the rest of keiki's authoring
    surface. Its new compile-all-starters target raises the package battery to 18 suites;
    all 18 passed, including 152 unit examples and 31 compiled starter modules.
  - EP-107 implementation found the qualified-table constant cannot live in the generated
    runtime module without creating an import cycle with the hand-owned query hole. A
    generated `ReadModelTable` leaf now owns the constant and is imported by both layers.
    It also confirmed the Kiroku package name is `kiroku-store` and used EP-103's delivered
    `DiffEnv` family registry directly, replacing the read-model out-of-scope marker.
  - EP-108 implementation confirmed through `mori registry search shibuya` that the
    package owning `Shibuya.Core.Ack` is `shibuya-core`, not the informal `shibuya`
    name. The process and router manifests now advertise the registered name, and the
    generated policy construction is pinned against the live package.
  - EP-108's first router target used state `Sent` beside event `PageSent`; EP-105's
    identifier-hygiene gate correctly rejected the shared `PageSent` constructor. The
    delivered fixture uses terminal state `Delivered`, demonstrating that the earlier
    gate hardening protects new verticals rather than merely legacy fixtures.
  - EP-108 added a runtime-free router-facts suite for its exact one-assertion mutation
    pin in addition to the live-runtime and filled-router suites. Together with EP-107's
    suite, the package battery is now 22 suites; all pass, with 181 unit/property
    examples and compiled target-keyed router-id and exact-resolver-target proofs.


## Decision Log

- Decision: assume MasterPlan 14 is implemented before this initiative; no child plan
  changes keiro/keiro-core/keiro-pgmq runtime code, and all plans consume MP-14's
  delivered surfaces (CommandAmbiguous, WorkerOptions policies, dead-letter records,
  confirmBenignDuplicate, read-model rebuild and Strong semantics).
  Rationale: user directive 2026-07-13; the DSL is a consumer of the runtime's forced
  decisions, and planning against a moving runtime would re-create the drift this
  initiative exists to fix.
  Date: 2026-07-13

- Decision: decompose into eight child plans across four phases — three gate-soundness
  plans (differ/validator/notation), one scaffolder plan, three node-surface verticals
  (readmodel, router+policies, remaining coverage), one delivery plan.
  Rationale: the findings cluster by the module whose contract they break, each cluster
  has its own test apparatus and reviewable shape, and the split mirrors MP-8's proven
  per-vertical pattern for the surface extensions. Alternatives (one giant gates plan,
  per-finding micro-plans, folding policies into the validator plan, gates fixed inside
  each vertical) rejected as documented in Decomposition Strategy.
  Date: 2026-07-13

- Decision: gates before surface — EP-107/108/109 hard-depend on EP-103's differ
  registry and soft-depend on EP-104/105/106.
  Rationale: new node families must register with sound machinery; a hard dependency on
  all three gate plans would over-serialize (validator and parser extensions are
  additive and reconcilable), but the differ is being structurally rewritten, so
  extending its old shape in parallel would guarantee rework.
  Date: 2026-07-13

- Decision: the audit findings are embedded verbatim (with verified file:line refs and
  repro snippets) into each child plan rather than referenced as an external document.
  Rationale: the consolidated findings file lives in an ephemeral session scratchpad;
  ExecPlans must be self-contained per the specification, and the repro snippets double
  as the plans' red fixtures.
  Date: 2026-07-13

- Decision: explicitly out of scope — delegated-idempotence intake (docs/plans/83 owns
  its own DSL surface once its runtime lands), sharding/consumer-group clauses
  (deployment-scoped, hole-kind 8), and every mechanism on the audit's "do not fix"
  list (overwrite/hole discipline, runtime API names, conformance architecture).
  Rationale: prevents duplicate ownership (the MP-14/MP-16 lesson), and the sound
  mechanisms are load-bearing for the fixes themselves.
  Date: 2026-07-13


## Outcomes & Retrospective

EP-104 completed the validator-soundness work stream. It added row-precise diagnostics,
workflow/rule/operation/process reference validation, collision detection, disposition
and topic safety, exact status maps, faithful queue fixture validation, and dispatch
dedup resolution. Its full package battery passed all 17 test suites. The initiative is
not complete.

EP-105 completed the notation-integrity work stream. It delivered lossless escaping,
reachable partial status maps, positioned duplicate and overflow errors, ASCII and
Haskell identifier hygiene, portable fixtures, and all-family adversarial round-trip
coverage. Its full package battery also passed all 17 suites. EP-106 through EP-110
remain; EP-106 owns the generated-Haskell side of the escaping contract, and the Phase 3
verticals must register every new node keyword in the parser's structural-word set.

EP-106 completed the scaffolder-hardening work stream. It delivered pre-write collision,
firewall, faithful-lowering, and banner gates; exact and escaped lowering for literals,
registers, status maps, windows, and backoff; compiling/pinned starter scaffolds; and a
versioned non-deleting stale-file record across namespace/layout changes. The authoring
docs reflect the delivered behavior, and the full package battery passed all 18 suites.
EP-107, EP-108, and EP-109 are now independently implementable; by registry order EP-107
is next.

EP-107 completed the first Phase 3 architecture vertical. The DSL now has first-class
read-model declarations with derived/captured identities, Strong-feed safety, schema and
column resolution across aggregates, queries, and dispatch, acyclic generated runtime and
SQL-hole modules, registration/rebuild/async wiring, derivation harnesses, and evolution
classification. The dedicated live-runtime conformance suite and the full package matrix
passed; the unit suite has 169 examples. EP-108 and EP-109 remain independently
implementable, with EP-108 next by registry order.

EP-108 completed the router and worker-policy vertical. The DSL now parses, validates,
diffs, scaffolds, and documents first-class routers; router stable names, keys, and
targets are evolution-sensitive; process and router rejection/poison choices lower to
explicit live `WorkerOptions`; and timer ambiguity is grammar-mandatory and generated as
its own `CommandAmbiguous` arm. Runtime-free mutation facts, live policy/id conformance,
a filled pure resolver over exact target streams, and the compile-all-starters suite are
green. The full 22-suite package battery passed, including 181 unit/property examples.
EP-109 is the next implementable child; EP-110 remains blocked on EP-109 as designed.


## Revision Notes

- 2026-07-13: Initial creation — eight child plans (103–110) across four phases,
  grounded in the 2026-07 keiro-dsl audit (gate soundness, scaffolder hazards,
  architecture-surface drift against post-MP-14 keiro, safe-API and skill refresh),
  with the standing assumption that MasterPlan 14 lands first and the audit's
  "do not fix" list binding.
- 2026-07-13: EP-107 completed. Registry/progress, cross-plan discoveries, and outcomes
  now record the first-class read-model grammar, scaffold, runtime conformance, and differ
  vertical; EP-108 is the next implementable child.
- 2026-07-13: EP-108 completed. Registry/progress, dependency-name and constructor-
  collision discoveries, policy/router runtime proofs, and the 22-suite package outcome
  are recorded; EP-109 is the next implementable child.
