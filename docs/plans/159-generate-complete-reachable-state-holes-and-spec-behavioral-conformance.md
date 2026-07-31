---
id: 159
slug: generate-complete-reachable-state-holes-and-spec-behavioral-conformance
title: "Generate complete reachable-state Holes and spec behavioral conformance"
kind: exec-plan
created_at: 2026-07-31T14:46:35Z
---

# Generate complete reachable-state Holes and spec behavioral conformance

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, a generated aggregate conformance target accounts for every finite behavior
obligation that the `.keiro` graph can soundly derive. Every live transition whose source state is
reachable through the live transition graph has a concrete accepting witness. Every reachable
state and command pair with no live transition has a concrete rejection witness. Every
replay-only transition has a historical replay witness instead of the impossible requirement that
it accept a new command. An accepted transition which deliberately emits no event is classified
as a no-op only when it leaves both the vertex and every register unchanged.

The result is observable in two different reports because the two evidence boundaries are
different. `keiro-dsl behavior-obligations FILE --format=json` reads a validated spec or workspace
and lists the required keys, locations, ownership, live reachability, and any unverified guard
surface. A consumer-compiled harness reads the typed histories, commands, and events from a new
create-once `BehaviorHoles.hs` module and emits `keiro/behavior-conformance/1` JSON containing filled,
pending, missing, duplicate, stale, failed, and unverified obligations. The compiled target exits
non-zero for pending, missing, duplicate, stale, or behaviorally false witnesses and names the
exact obligation.

This is complete bookkeeping and execution for a finite witness suite, not exhaustive proof over
all command values, register valuations, or histories. Generated-owned version-2 transitions from
[Plan 161](161-add-authoritative-typed-scalar-aggregate-expressions.md) can be called
source-behavior conformance because the runtime necessarily executes the checked guard and writes.
Explicit Hole-owned transitions receive only finite witnessed-conformance status, and opaque guard
coverage remains visibly unverified. Released version-1 aggregate-wide transducer Holes are not
silently upgraded to source-behavior conformance: their reports are labelled runtime-witness-only.


## Progress

- [x] 2026-07-31: audited the draft against the current DSL, scaffold ownership model, ADRs,
  Keiki `0.5.0.0`, Hackage preferred metadata, and upstream tag `v0.5.0.0`; revised the plan to
  remove unsound or unimplementable claims.
- [x] 2026-07-31: filed the missing detailed forward/replay attribution capability as
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`; current Mori resolution awaits a
  registry refresh, but the canonical producer-owned handle is fixed.
- [ ] Milestone 1: land or verify the authoritative version-2 transducer seam from Plan 161 and a
  released Keiki detailed-step/detailed-replay attribution API.
- [ ] Milestone 2: derive versioned live-cell, live-transition, rejection, replay-transition, and
  unverified-evidence descriptors and persist them in single-spec and workspace records.
- [ ] Milestone 3: generate the create-once typed witness surface and migration snippets without
  parsing, merging, or overwriting consumer Haskell.
- [ ] Milestone 4: execute live and replay witnesses through the generated codec and authoritative
  transducer, reconcile the runtime report, and introduce the explicit enforcement gate.
- [ ] Milestone 5: add compiled conformance, mutation, workspace, regeneration, documentation,
  release, and full-repository validation.


## Surprises & Discoveries

- 2026-07-31: `Keiro.Dsl.Harness.initialTransitions` selects transitions solely from the first
  declared state. The current generated suite can stay green while every later-state transition is
  missing from the witness corpus or behaves incorrectly.
- 2026-07-31: Keiki `0.5.0.0` already exposes `stepEither`, which distinguishes
  `NoOutgoingEdges`, `NoMatchingEdge`, `AmbiguousEdges`, and an accepted empty-output edge. The
  earlier `Rejects Text` proposal is therefore both too weak for ambiguity and too strong for
  domain reasons: released Keiro has no typed business-rejection reason to compare.
- 2026-07-31: a successful `stepEither` result does not expose the accepted `EdgeRef`, and
  `applyEventsEither` does not expose replay attribution. Target vertex and emitted values cannot
  distinguish two guarded alternatives with the same structural envelope. Exact transition
  coverage therefore needs a small Keiki trace API; inferring the edge in generated code would
  duplicate or guess core semantics.
- 2026-07-31: `ReplayOnly` edges are deliberately excluded from `step`, `delta`, and `stepEither`.
  Requiring an accepting forward witness for every declared transition is impossible and would
  contradict [ADR 2](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md).
- 2026-07-31: `Validate.hs` computes structural reachability through both live and replay-only
  transitions because replay-only targets must remain available to historical streams. New-command
  cells need a separate live-only reachability traversal; replay obligations need historical
  reachability proven by their event histories.
- 2026-07-31: the single-spec and workspace scaffold writers treat `Holes.hs` as create-once and
  never merge Haskell declarations. Their records already provide the sound pattern: persist
  obligation descriptors, report additions and removals, and leave consumer edits untouched.
- 2026-07-31: a spec-only CLI cannot truthfully report whether typed Haskell histories, commands,
  and expectations are filled. Static obligation inventory belongs in the CLI; filled/missing/
  stale reconciliation belongs in the compiled harness.
- 2026-07-31: version-1 guard and write expressions are comments beside an aggregate-wide
  consumer transducer. Until Plan 161 makes version-2 generated expressions authoritative, a
  witness can test runtime behavior but cannot prove that runtime behavior conforms to the source
  expression.
- 2026-07-31: Hackage preferred-version metadata and the upstream tag both identify Keiki
  `0.5.0.0` as the current release. The local Mori corpus located the source correctly but was not
  used as release authority.


## Decision Log

- Decision: Define the plan's guarantee as complete finite witness obligations with explicit
  evidence levels, not complete behavioral proof.
  Rationale: command values, register valuations, and histories can be infinite, and one example
  cannot prove behavior for all of them. The report must never upgrade finite examples or opaque
  Hole behavior into a universal claim.
  Date: 2026-07-31

- Decision: Derive new-command cells from states structurally reachable through live transitions
  only, including reachable terminal states, and derive replay-only obligations separately.
  Rationale: replay-only edges can preserve historical continuation but can never accept a new
  command. Terminal-state command rejection remains real observable behavior and should not
  disappear from the denominator.
  Date: 2026-07-31

- Decision: Require one accepting witness per reachable live transition, one rejection witness
  for each reachable state/command cell with no live transition, and one replay witness per
  replay-only transition. A live transition witness also satisfies its state/command cell.
  Rationale: this closes the initial-state and guarded-alternative blind spots without claiming
  exhaustive coverage of possible guard gaps within a cell. Guard-union totality is reported as
  proved, partial, or unknown when that analysis is available; it is not fabricated from samples.
  Date: 2026-07-31

- Decision: Interpret `NoOp` narrowly as an accepted live edge with an empty event list, unchanged
  vertex, and unchanged registers. Reject source declarations that change state or registers
  without an event before obligation generation.
  Rationale: event-sourced state changes with no persisted evidence cannot replay. Keiki already
  treats state-changing epsilon edges as a default validation failure; the source checker should
  fail the same defect at the earliest boundary.
  Date: 2026-07-31

- Decision: Compare current rejection only as `NoOutgoingEdges` or `NoMatchingEdge`; treat
  `AmbiguousEdges` as an unconditional conformance failure. Add domain rejection/no-op reasons only
  after the proposed
  [typed outcome request](../improvement-requests/return-typed-domain-command-outcomes-and-rejection-details.md)
  lands.
  Rationale: these are the distinctions the released Keiki and Keiro APIs actually expose. An
  arbitrary `Text` expectation would be unverifiable and would conflate business rejection with a
  nondeterministic machine.
  Date: 2026-07-31

- Decision: Add a Keiki detailed forward result and detailed replay attribution trace before
  claiming per-transition coverage, tracked by
  `mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`.
  Rationale: source/command/target and event equality do not uniquely identify guarded siblings.
  The core evaluator knows the chosen `EdgeRef` and live/replay-only mode; the harness must consume
  that fact rather than reproduce edge selection.
  Date: 2026-07-31

- Decision: Route witness histories and actual emitted events through the generated wire codec
  before replay, and compare final vertex plus every declared register.
  Rationale: persisted bytes, not in-memory event values, rebuild the aggregate. Register files
  have no whole-value `Eq`, so generated per-register comparisons remain the supported equality
  seam established by Plan 147.
  Date: 2026-07-31

- Decision: Keep witnesses in a separate create-once
  `<Context>.<Aggregate>.BehaviorHoles` list containing explicit `Pending` entries and filled typed
  cases. Re-scaffolding records new and removed keys and prints paste-ready migration snippets but
  never parses or merges Haskell.
  Rationale: automatic source merging is not part of the current ownership contract and cannot be
  made sound from formatted Haskell text. A separate HoleStub can be added safely beside an
  existing aggregate `Holes.hs` without changing its exports or behavior implementation. Runtime
  reconciliation can report absent and stale keys without destroying filled work.
  Date: 2026-07-31

- Decision: Split static and compiled reports. The CLI emits only required descriptors; the
  consumer-compiled harness emits filled, missing, stale, duplicate, result, and evidence status.
  Rationale: the CLI has the spec graph but cannot execute or inspect application Haskell. The
  compiled target has both the generated requirements and the typed witness values.
  Date: 2026-07-31

- Decision: Transition keys are derived from a versioned canonical semantic fingerprint, never a
  line number or list ordinal. The fingerprint covers context, aggregate, mode, source, command,
  typed guard, ordered writes, ordered emitted event kinds, target, and ownership envelope; source
  locations remain diagnostic metadata.
  Rationale: keys must survive line movement and canonical pretty printing, while a semantic edit
  must create a new obligation and leave the previous witness visibly stale. Fingerprint collisions
  or duplicate required keys are validation errors, not report entries to tolerate.
  Date: 2026-07-31

- Decision: Make generated-owned version-2 transitions a hard prerequisite for the
  source-conformance label. Legacy version 1 is runtime-witness-only; explicit version-2
  Hole-owned transitions are finite witnessed conformance with opacity metadata.
  Rationale: only generated ownership makes the checked source expression the runtime authority.
  This follows proposed [ADR 17](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  and avoids retroactively changing released version-1 scaffolds.
  Date: 2026-07-31

- Decision: Roll out the compiled failure gate only after obligation reporting, record migration,
  and all checked-in consumer fixtures are updated. Keep unverified Hole/opaque evidence visible
  and separately gateable instead of making the permanent escape hatch unusable.
  Rationale: reporting-first migration follows the evidence-honesty principle of
  [ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md)
  without pretending that ADR 13's structural-coverage policy itself defines this new report.
  Date: 2026-07-31

- Decision: Keep this follow-on as a standalone ExecPlan, with Plan 161 Milestone 3 as a hard
  integration dependency rather than reopening the completed structural-consumer-type MasterPlan.
  Rationale: static obligation derivation can proceed independently, but source-behavior execution
  must use the authoritative generated transducer rather than create a second implementation.
  Date: 2026-07-31


## Outcomes & Retrospective

The 2026-07-31 audit changed planning only. It removed an impossible forward requirement for
replay-only edges, replaced unverifiable rejection text with released structured outcomes, split
static and compiled evidence at the correct boundary, and removed automatic `Holes.hs` merging.
It also made the Plan 161 ownership dependency explicit and added the missing Keiki edge-
attribution prerequisite.

Implementation remains pending. At each milestone, record the released Keiki version and tag,
required/filled/pending/stale counts for the fixture, evidence-level counts, and any remaining
guard or Hole opacity. Before completion, distill durable decisions into the relevant ADRs.


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Grammar.hs` defines aggregate states, commands, transitions, guards,
ordered writes, emitted event kinds, live/replay-only mode, and source locations.
`keiro-dsl/src/Keiro/Dsl/Validate.hs` validates declared references and computes structural
reachability, but its current traversal follows both transition modes. Add the live-only traversal
in a new `keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs` module after normal validation succeeds;
do not duplicate name, type, or graph-integrity validation there.

`keiro-dsl/src/Keiro/Dsl/Harness.hs` renders aggregate harness modules. Its
`initialTransitions` helper currently restricts acceptance and forward/replay checks to the first
declared state. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs` renders aggregate modules and the create-once
`Holes.hs`; `emitHoles` currently places the whole version-1 transducer there. Plan 161 changes the
version-2 ownership seam so generated assembly executes generated-owned expressions and consumes
only explicit per-transition Hole implementations and output hooks.

`keiro-dsl/src/Keiro/Dsl/ScaffoldRun.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceScaffold.hs` never overwrite `HoleStub` modules. Their records,
`keiro-dsl/src/Keiro/Dsl/ScaffoldRecord.hs` and
`keiro-dsl/src/Keiro/Dsl/WorkspaceRecord.hs`, already persist mapped binding obligations and report
new ones. Behavioral obligation rows should use the same additive, unknown-row-tolerant pattern.
For workspaces, derive once from `WorkspaceSpec.wsMergedSpec`, retain the owning member for each
aggregate descriptor, and keep the record keyed by the manifest service as required by
[ADR 14](../adr/0014-service-workspaces-compose-single-owner-members-under-one-manifest-identity.md)
and [ADR 15](../adr/0015-workspace-scaffold-history-is-workspace-keyed-with-attributable-adoption.md).

The runtime dependency is `mori://shinzui/keiki/packages/keiki`. Released Keiki `0.5.0.0` defines
`stepEither`, `StepFailure`, `EdgeRef`, `applyEventsEither`, and replay failures in the canonical
project `mori://shinzui/keiki`, project-relative file `src/Keiki/Core.hs`; a source-file artifact
URI is pending. `stepEither` returns the final state, registers, and events on success but not the
chosen edge. Replay returns the final state or a structured failure but not a successful edge
trace. The dependency milestone must add those facts without exposing register values in
diagnostics or introducing a second evaluator, release Keiki, and verify the chosen release
against Hackage metadata and its upstream tag before changing Cabal bounds.
Keiki owns this capability through
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`.

[Plan 147](147-generate-forward-versus-replay-equality-assertions-in-the-dsl-harness.md)
established codec-crossing forward/replay equality for sampled initial-state live transitions.
This plan generalizes that execution shape to consumer-supplied histories and all finite
obligations. Plan 161 owns the authoritative version-2 transducer and exclusive generated/Hole
behavior ownership; this plan owns witness declaration, reconciliation, and execution only.

[ADR 2](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
defines live-first replay attribution and why replay-only edges cannot be forward witnesses.
[ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md) requires invalid
source-level epsilon changes and duplicate obligation identities to fail during checking, while
runtime witness mismatch fails in conformance. ADR 13 requires honest reporting around unverified
or opaque evidence. Proposed ADR 17 defines the ownership labels this report must preserve.

A “live-reachable state” is the initial state or a target reachable by following only declared
live transitions, without claiming that every guard is satisfiable. A “behavioral cell” is one
live-reachable state and declared command constructor. A “live-transition obligation” is one
declared live transition from a live-reachable source. A “replay-transition obligation” is one
declared replay-only transition exercised by an observed historical event chunk. A “witness” is a
typed event history plus, for live behavior, a typed command and observable expectation. A witness
proves that concrete example only. “Unverified” means the available symbolic structure cannot
prove a wider property, not that the witness passed.


## Plan of Work

Milestone 1 establishes the only sound edge-attribution seam. First verify that Plan 161's
generated version-2 assembly exists and exposes one authoritative transducer plus a stable mapping
from transition obligation keys to generated edges. Implement or consume
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`: in the Keiki project, add an additive detailed
forward function whose success includes `EdgeRef`, and a detailed strict replay function whose
trace records the attributed `EdgeRef`, `EdgeMode`, and consumed event span for each completed
edge, including multi-event chains. The compatibility `stepEither` and `applyEventsEither`
functions remain unchanged. Tests must prove live-first selection over a replay-only twin,
same-target guarded siblings, multi-event spans, ambiguity, and truncated replay. Release Keiki,
verify Hackage preferred metadata and the matching tag, then select Keiro bounds from that released
API. A small spike in this milestone should prove the generated mapping and detailed trace identify
the same edge; do not proceed on target/event inference alone.

Milestone 2 adds pure obligation derivation. `Keiro.Dsl.BehaviorCoverage` consumes only a validated
semantic `Spec`. Traverse live edges from the first declared state, include terminal targets, and
form every state/command cell. Emit one transition obligation for each live transition from a
live-reachable source. A cell with no live transition receives a rejection obligation. A live
transition which emits nothing is eligible only when source equals target and it has no writes;
otherwise `check` emits an append-only error code before scaffolding. Emit a distinct replay
obligation for every replay-only transition and require its runtime history to prove the source is
historically reachable.

Canonical requirement keys use a versioned semantic fingerprint. A line move changes only display
metadata; a guard, write, emitted-kind order, target, mode, or ownership-envelope change creates a
new key. Detect duplicate canonical transition identities and hash collisions as validation errors.
Describe guard-union evidence per cell as proved total, provably partial over the symbolic
over-approximation, or unknown. Because structural reachability does not characterize reachable
register valuations, this status is evidence metadata and never manufactures a required negative
witness for a cell that already has live transitions.

Expose the static inventory through `keiro-dsl behavior-obligations FILE --format=text|json` for
both `.keiro` and `.keiro-workspace` inputs. The JSON schema is
`keiro-dsl/behavior-obligations/1` and contains requirements, locations, owning member when
applicable, evidence levels, and no filled/missing claims. Add additive behavior rows to the
single-spec and workspace scaffold records. Re-scaffold reports new and removed obligations before
writing generated files, but never inspects consumer Haskell.

Milestone 3 creates the typed consumer seam. Generate an aggregate-specific
`Generated.<Context>.<Aggregate>.BehaviorContract` module and a separate create-once
`<Context>.<Aggregate>.BehaviorHoles` module exporting one `behaviorWitnesses` list. Leave the
existing aggregate `Holes.hs` implementation module unchanged. The witness list contains
either `Pending key` or a typed `LiveWitness`/`ReplayWitness`; it compiles without `undefined`,
`error`, or invented command values. On a first scaffold, emit one `Pending` row for each current
requirement. On later scaffolds, leave the file byte-for-byte untouched, report absent new keys,
and print deterministic paste-ready snippets. Removed or changed keys remain compilable text and
become stale in the compiled report; automatic deletion and Haskell AST merging are forbidden.

Generated-owned modules carry the canonical required descriptors and transition-to-edge map.
Consumer code writes concrete histories, commands, exact expected event values, and the expected
rejection class. For a Hole-owned transition it also pins the implementation's declared fold
version so a manual behavior change requires an explicit witness review. Version-1 compatibility
may expose a separately labelled runtime-witness list, but regeneration must not reshape or replace
its aggregate-wide transducer Hole.

Milestone 4 executes and reconciles witnesses. Decode every event in a witness history through the
generated codec, then replay from the transducer's initial state and registers. A live witness must
end at the obligation's source state before calling detailed step. `Emits` requires the exact
accepted edge, target, ordered event-kind envelope, exact event values, and codec-decoded event
chain; replay the actual decoded emissions from the pre-command state and compare final vertex and
every register with forward execution. `NoOp` requires the exact accepted edge, empty output,
unchanged vertex, and unchanged registers. `Rejects` accepts only the expected
`NoOutgoingEdges`/`NoMatchingEdge` class; `AmbiguousEdges` always fails.

A replay witness separately supplies a decoded prefix and the exact observed event chunk for one
replay-only transition. Detailed replay must attribute the completed chunk to the expected
replay-only edge, start at the declared source, consume the whole chunk, and finish at the declared
target. A live attribution where a replay-only attribution was expected fails, proving live-first
semantics rather than merely reaching the same target. There is no forward comparison for a
replay-only edge because it is intentionally absent from the new-command path.

Reconcile generated requirements and consumer rows into `keiro/behavior-conformance/1`. Duplicate
consumer keys, stale keys, pending rows, missing keys, invalid histories, false expectations, and
edge-attribution mismatches make the compiled conformance target fail. Generated-owned, Hole-owned,
legacy-runtime-only, and guard-unknown counts remain separate. An explicit `--fail-on-unverified`
policy may make Hole/unknown evidence fail, but the default completeness gate must not relabel those
surfaces as proved.

Milestone 5 proves the design with a version-2 aggregate fixture containing at least three states,
one terminal state, commands absent from some states, two same-source/same-command guarded live
alternatives that share a target, a valid eventless self-loop no-op, and a live/replay-only twin.
Use exact consumer histories to reach later states. Add mutations that remove a later-state
witness, use a history reaching the wrong source, swap sibling transition keys while target and
event kind stay equal, change rejection to no-op, change a no-op register, omit one guard
alternative, expect a replay-only edge to fire forward, let the live twin steal a replay witness,
truncate a multi-event replay chunk, and make codec replay diverge. Each mutation must fail the
named obligation and restore its target even after interruption.

Regenerate every checked-in version-2 aggregate harness, add single-file and workspace record
round trips, and prove re-scaffolding never changes a filled `BehaviorHoles.hs` file. Update
`docs/user/typed-spec-toolchain.md`, `docs/guides/evolution-and-replayability.md`,
`keiro-dsl/CHANGELOG.md`, package manifests, and the authoring skill/corpus if they describe the
old initial-state-only behavior. Amend ADR 4's boundary inventory and ADR 17's conformance
consequences when implementation confirms the interfaces; amend ADR 13 only if its actual
structural-coverage policy changes.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. Re-establish the dependency source through Mori:

```bash
mori registry list
mori registry search keiki
mori registry show shinzui/keiki --full
mori registry docs shinzui/keiki
mori registry dependents shinzui/keiki --packages
mori path mori://shinzui/keiki/packages/keiki
```

Before changing dependency bounds, verify the current released API independently:

```bash
curl -fsSL https://hackage.haskell.org/package/keiki/preferred.json
git ls-remote --tags https://github.com/shinzui/keiki.git
```

After Milestone 2, the static fixture inventory should be deterministic:

```bash
cabal run keiro-dsl -- behavior-obligations \
  keiro-dsl/test/fixtures/behavior-complete.keiro \
  --format=json
```

The output must identify schema `keiro-dsl/behavior-obligations/1`, list later-state and terminal
cells, separate live and replay-only requirements, and make no claim about filled witnesses.

After Milestone 4, run the compiled fixture report and gate:

```bash
cabal test keiro-dsl-conformance-behavior-complete
cabal run keiro-dsl-behavior-complete-report -- --format=json
```

Before filling the create-once witness file, the report exits non-zero with non-empty `pending` or
`missing`. After filling it, `pending`, `missing`, `duplicate`, `stale`, and `failed` are empty;
the report still lists any Hole-owned or guard-unknown evidence under `unverified` rather than
`verified`.

Run focused and repository validation:

```bash
cabal test keiro-dsl-test --test-options='--match=behavior obligations'
bash keiro-dsl/test/behavior-complete-mutation-test.sh
cabal test keiro-dsl-test
cabal build all
nix flake check
okf validate docs/adr \
  --strict \
  --profile docs/adr/profile.dhall \
  --profile-enforce \
  --log-enforce
```

Record exact fixture counts and released dependency versions in Progress when each milestone
completes.


## Validation and Acceptance

1. A fixture history reaches a later nonterminal state and exercises every command cell there; a
   reachable terminal state has rejection witnesses for every command. Removing one later-state
   row fails while the old initial-state assertions remain green.
2. Every reachable live transition, including same-target guarded siblings, is identified by the
   detailed accepted `EdgeRef`. Swapping their keys fails even when target and emitted constructor
   are unchanged.
3. Every replay-only transition is exercised through detailed replay and is never required or
   allowed to fire forward. A live-twin attribution mutation fails the replay-only obligation.
4. Histories cross the generated codec, must replay from the true initial seed, must end settled at
   the declared source, and cannot construct an internal state/register tuple directly.
5. `Emits` compares exact ordered events, the declared event-kind envelope, target, and
   forward/replay final vertex and registers. A dishonest codec or update mutation fails.
6. `Rejects` distinguishes `NoOutgoingEdges` from `NoMatchingEdge`; `AmbiguousEdges` can never be
   an expected rejection. `NoOp` requires an accepted edge with no events and no vertex/register
   change.
7. The static CLI report never claims consumer fill status. The compiled report deterministically
   separates required, filled, pending, missing, duplicate, stale, failed, verified, and unverified
   entries for both one-file and workspace scaffolds.
8. Semantic transition edits create new keys and leave old witnesses stale; line movement and
   canonical pretty printing do not change keys. Duplicate required identities or key collisions
   fail validation before scaffolding.
9. Re-scaffolding preserves `BehaviorHoles.hs` and the aggregate `Holes.hs` exactly, prints
   deterministic additions/removals,
   keeps stale rows until the consumer removes them, and produces byte-identical generated output
   for unchanged input. A workspace re-run reports generated modules unchanged.
10. Version-2 generated-owned rows are labelled source-conformant; version-2 Hole-owned rows are
    labelled finite witnessed/unverified as applicable; legacy version-1 rows are never labelled
    source-conformant.


## Idempotence and Recovery

Obligation derivation, canonical keys, static reports, generated descriptors, runtime reports, and
migration snippets are deterministic. Required descriptors are appended to the existing
forward-compatible record formats; older readers ignore the unknown row kind. A failed preflight
must leave generated files, consumer files, build manifests, and records untouched according to
the existing single-spec and workspace planning boundaries.

Both aggregate `Holes.hs` and witness `BehaviorHoles.hs` remain create-once. Never overwrite,
parse, or auto-delete witness rows. If scaffolding stops after generated modules are written on the
single-spec path, rerunning produces the same generated bytes and again skips both consumer files.
Workspace scaffolding retains its existing
preflight-before-write and unchanged-byte behavior. A stale witness remains a failing, recoverable
row until a human removes or updates it.

Do not enable the completeness gate until reports and checked-in fixture migrations work. If the
Keiki detailed API cannot identify successful forward and replay edge attribution, stop after the
Milestone 1 spike and update this plan; target/event inference is not an acceptable fallback. All
mutation scripts must use the repository's existing restore-on-exit pattern.


## Interfaces and Dependencies

`Keiro.Dsl.BehaviorCoverage` should expose pure equivalents of the following build-time types and
functions. Names may adapt to repository conventions, but the distinctions may not collapse:

```haskell
newtype BehaviorKey = BehaviorKey Text

data ObligationKind
  = LiveTransition
  | RequiredRejection
  | ReplayTransition

data EvidenceLevel
  = GeneratedAuthoritative
  | HoleWitnessed
  | LegacyRuntimeWitness
  | GuardCoverageUnknown

data BehaviorRequirement = BehaviorRequirement
  { requirementKey :: BehaviorKey
  , requirementKind :: ObligationKind
  , requirementEvidence :: EvidenceLevel
  , requirementLocation :: Loc
  }

deriveBehaviorRequirements :: Spec -> Either [BehaviorDerivationError] [BehaviorRequirement]
```

The generated aggregate contract should provide typed equivalents of:

```haskell
data RejectionClass
  = RejectNoOutgoingEdges
  | RejectNoMatchingEdge

data LiveExpectation event
  = Emits (NonEmpty event)
  | Rejects RejectionClass
  | NoOp

data BehaviorWitness command event
  = Pending BehaviorKey
  | LiveWitness
      { witnessKey :: BehaviorKey
      , history :: [event]
      , command :: command
      , expected :: LiveExpectation event
      }
  | ReplayWitness
      { witnessKey :: BehaviorKey
      , historyPrefix :: [event]
      , observedChunk :: [event]
      }
```

Here `NonEmpty` is `Data.List.NonEmpty.NonEmpty`, making an empty accepted event chain representable
only as `NoOp`. The real implementation may use separate live and replay types to avoid partial
record fields. Keys in consumer code remain textual/versioned so a removed generated constant does
not make stale witnesses uncompilable. Generated descriptors parse and validate those keys before
reconciliation.

The compiled result must expose a pure `behaviorCoverageReport` plus labeled assertions or a
structured runner. Its JSON schema `keiro/behavior-conformance/1` contains required, filled,
pending, missing, duplicate, stale, failed, verified, and unverified collections, with stable
machine-readable failure codes and human-readable state, command, transition, and source-location
detail. Report arrays are canonically sorted by `BehaviorKey`.

The required Keiki dependency surface is additive: a successful detailed step returns the chosen
`EdgeRef` with the existing target/register/event result, and strict detailed replay returns
successful edge attributions including mode and event spans while retaining existing structured
failures. Compatibility entry points keep their released signatures. Use the one Keiki evaluator
for guard selection, updates, emission, and replay; generated code must not implement an edge
selector. The producer-owned request is
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2`.

Plan 161's generated transducer and transition-to-edge mapping are hard dependencies for the
source-conformance label. The current released dependency is
`mori://shinzui/keiki/packages/keiki` version `0.5.0.0`, but implementation must repeat registry and
upstream release verification and choose bounds only after the detailed API is released.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.

Revision note: Revalidated the plan against current Keiro/Keiki source, released Keiki `0.5.0.0`,
the scaffold ownership contract, Plans 147 and 161, and ADRs 2, 4, 13, 14, 15, and 17. Replaced
impossible replay-only forward witnesses, unverifiable rejection text, spec-only fill reporting,
and automatic Haskell merging with mode-correct edge-attributed witnesses, evidence-labelled
reports, additive record drift, and create-once consumer reconciliation, 2026-07-31.

Revision note: Filed the missing successful edge-attribution capability in Keiki as
`mori://shinzui/keiki/okf/improvement-requests/concepts/IR-2` and linked the prerequisite from
Progress, Decision Log, Context, Milestone 1, and Interfaces; local resolution is pending a Mori
registry refresh, 2026-07-31.
