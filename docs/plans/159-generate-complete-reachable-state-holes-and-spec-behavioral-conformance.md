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

After this change, the generated `Holes` and harness modules describe and execute the aggregate's
whole declared command behavior, not only transitions leaving the initial state. For every
reachable state and command, an application must provide at least one witnessed outcome: emitted
events, an intentional rejection, or an intentional no-op. Every declared transition, including
guard alternatives, must have an accepting witness. The harness replays each witness history,
runs the command, checks the declared outcome, and proves that emitted events replay to the same
state and registers as forward execution.

The result is observable through a generated coverage report. A scaffold with an unfilled cell or
an unwitnessed transition does not quietly pass: its conformance target fails with the exact state,
command, and transition obligation that remains. This closes the gap left by the initial-state-only
checks in the current generated harness.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: define stable behavioral obligation, witness, expectation, and report types.
- [ ] Milestone 2: derive the complete reachable-state/command/transition obligation set and emit
  consumer-owned holes without overwriting filled work.
- [ ] Milestone 3: execute histories and commands against forward and replay semantics, including
  accepted, rejected, and no-op outcomes.
- [ ] Milestone 4: add compiled conformance and mutation suites, documentation, diagnostics, and
  full repository validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-31: `Keiro.Dsl.Harness.initialTransitions` selects transitions solely from the first
  declared state. The current generated suite can therefore stay green while every later-state
  transition is missing from `Holes` or behaves incorrectly.
- 2026-07-31: Completed plan 147 intentionally established forward/replay parity for generated
  command behavior without claiming every command in every reachable state. This plan extends its
  contract instead of treating that narrower milestone as complete behavioral conformance.


## Decision Log

Record every decision made while working on the plan.

- Decision: Define completeness over the finite product of graph-reachable declared states and
  declared commands, plus one accepting witness for every declared transition.
  Rationale: Register valuations and command values may be infinite, but the state graph and
  transition declarations are finite. This boundary detects missing state/command behavior and
  every guard branch without pretending to exhaust arbitrary data domains.
  Date: 2026-07-31

- Decision: Require histories as event sequences and verify that each history replays to its
  claimed source state before executing the command.
  Rationale: Constructing an internal state/register tuple directly could admit unreachable test
  states and bypass the aggregate's real event evolution semantics.
  Date: 2026-07-31

- Decision: Model `Emits`, `Rejects`, and `NoOp` as distinct public expectations.
  Rationale: A missing transition may intentionally reject or do nothing; treating both as an empty
  event list loses domain intent and can hide a change from rejection to successful no-op.
  Date: 2026-07-31

- Decision: Keep application witnesses in consumer-owned `Holes.hs`, merge additions by stable
  obligation key, and never synthesize semantic command values beyond deterministic placeholders.
  Rationale: Keiro can derive which behaviors need evidence but cannot invent valid business inputs
  for arbitrary guards. Stable keys let scaffold add new obligations without erasing filled cases.
  Date: 2026-07-31

- Decision: Keep this audit follow-on as a standalone ExecPlan rather than reopening the completed
  structural-consumer-type MasterPlan.
  Rationale: Behavioral completeness is independently implementable and should not make a shipped
  initiative appear unfinished again.
  Date: 2026-07-31


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`keiro-dsl/src/Keiro/Dsl/Harness.hs` renders the generated harness and the consumer-owned hole
module. Its `initialTransitions` function filters the transition list by the first declared state,
and its generated acceptance cases are built only from that list. `keiro-dsl/src/Keiro/Dsl/Scaffold.hs`
assembles generated modules, while `ScaffoldRun.hs` and scaffold records protect consumer-owned
files during regeneration. `Grammar.hs` provides states, commands, transitions, guards, writes,
and emitted events. `Validate.hs` already checks graph and name integrity, so obligation derivation
must consume the validated aggregate rather than duplicate those checks.

The compiled suites under `keiro-dsl/test/conformance*/` demonstrate generated code against Keiki
and Keiro. [Plan 147](147-generate-forward-versus-replay-equality-assertions-in-the-dsl-harness.md)
created the existing forward/replay seam. [Plan 148](148-report-evolution-as-a-compatibility-vector-with-remediation-explanations.md)
created persistent scaffold ownership and merge behavior. This plan builds on both.

[ADR 13](../adr/0013-structural-coverage-is-reporting-first-and-opacity-gates-are-opt-in.md) requires coverage to be observable
before it becomes an enforcement gate. The implementation must therefore ship a report mode and
record format before making missing cells fail the compiled target. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires structural impossibilities, such as duplicate obligation keys or a history that cannot
reach its claimed state, to fail at the earliest sound boundary.

A “behavioral cell” is one `(reachable state, command constructor)` pair. A “transition obligation”
is one stable identity for a declared transition, including its source, command, target, and source
location/fingerprint. A “witness” is a concrete event history and command value with an expected
outcome. Complete conformance means all cells and all transition obligations have truthful
witnesses; it does not mean exhaustive testing of every field value.


## Plan of Work

Milestone 1 adds a small public conformance vocabulary in a generated support module and a pure
obligation derivation module in `keiro-dsl/src/Keiro/Dsl/BehaviorCoverage.hs`. Stable obligation
keys must derive from canonical context, aggregate, source state, command, target, and a disambiguator
for guarded alternatives; source line numbers may be displayed but must not be identity. The report
contains required, filled, missing, duplicate, and stale keys and can be rendered as text and JSON.

Milestone 2 updates `Harness.hs`, `Scaffold.hs`, `ScaffoldRun.hs`, `ScaffoldRecord.hs`, and
`WorkspaceRecord.hs`. Generate one editable entry per behavioral cell and transition obligation in
`<Context>/<Aggregate>/Holes.hs`. On re-scaffold, preserve entries with matching keys, append new
stubs, and report stale entries without deleting them. Add `keiro-dsl conformance-coverage` for a
single spec or workspace. Following ADR 13, first expose missing obligations in the report, then
make the generated conformance executable fail after applications have a generated migration path.

Milestone 3 replaces `initialTransitions` with complete case execution. For each witness, replay
the history through the generated event stream, confirm the reached vertex, run the concrete
command from that state/register pair, and compare the actual result with `Emits expectedEvents`,
`Rejects expectedReason`, or `NoOp`. For `Emits`, apply the actual event list forward and replay it
from the pre-command state and require identical final state and registers. Require the witness's
transition key to match the actual source/command/target path. Rejection must be distinguishable
from no-op at the generated seam even if Keiki currently represents both without an emitted event;
if the runtime cannot expose that distinction, add the smallest typed decision wrapper in generated
code and document the boundary rather than comparing only `[]`.

Milestone 4 creates a multi-state, guarded aggregate fixture with at least three states, commands
that accept in one state and reject/no-op in others, and two guarded transitions for the same
command. Add mutation tests that remove a later-state witness, lie about a source state, change
`Rejects` to `NoOp`, omit one guard alternative, and make replay diverge. Update authoring,
toolchain, scaffold ownership, and changelog documentation. Amend ADR 13 when enforcement is
enabled and ADR 4 if new persistent diagnostic codes are allocated.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
cabal test keiro-dsl-test --test-options='--match=behavior.*coverage'
cabal test keiro-dsl-conformance-behavior-complete
cabal run keiro-dsl -- conformance-coverage keiro-dsl/test/fixtures/behavior-complete.keiro --format=json
bash keiro-dsl/test/behavior-complete-mutation-test.sh
cabal test keiro-dsl-test
cabal build all
nix flake check
```

Before all holes are filled, the JSON report should include a non-empty `missing` array and the
compiled target should name the exact missing key. After filling the fixture, expected report
counts are `missing = 0`, `duplicates = 0`, and `stale = 0`, with every declared transition in
`witnessedTransitions`. Record the final counts in Progress during implementation.


## Validation and Acceptance

1. Reachability starts at the declared initial state and follows the validated transition graph.
   Unreachable declared states remain a validation error or appear separately; they do not create
   impossible behavioral cells.
2. Every reachable state/command pair has a filled witness whose replayed history reaches that
   state. Every transition declaration, including each guarded alternative, has an `Emits` witness.
3. Removing the only later-state witness fails while the old initial-state cases remain green,
   proving the original blind spot is closed.
4. Accepted cases compare the exact ordered event list and prove forward/replay final-state parity.
   Rejected and no-op cases are separately asserted and a mutation between them fails.
5. Coverage reports are deterministic text and JSON, work for one-file and workspace specs, and
   use stable keys that survive line movement and pretty printing.
6. Re-scaffolding preserves filled consumer cases, appends new stubs, reports stale cases, and is
   byte-identical when the spec and filled holes have not changed.
7. The generated conformance suite compiles without `undefined`, `error`, or placeholder values in
   generated-owned modules. Unfilled consumer holes fail clearly rather than being silently skipped.


## Idempotence and Recovery

Coverage derivation, reporting, and generated support files are deterministic. The scaffolder must
write consumer-owned changes through its existing staged merge path. Keep a stale witness in place
and report it until the user removes it; automatic deletion is not recoverable and is forbidden.

Introduce enforcement only after report output and fixture migration are working, following ADR
13. If case execution exposes that rejection and no-op cannot be observed distinctly, stop at the
typed generated-decision seam and update this living plan; do not label both outcomes as complete.
All mutations must restore their target files even on failure, following the existing mutation
test pattern.


## Interfaces and Dependencies

`Keiro.Dsl.BehaviorCoverage` must expose pure equivalents of:

```haskell
data BehaviorKey = BehaviorKey Text
data BehaviorExpectation event
  = Emits BehaviorKey [event]
  | Rejects Text
  | NoOp

data BehaviorWitness command event = BehaviorWitness
  { key :: BehaviorKey
  , history :: [event]
  , command :: command
  , expected :: BehaviorExpectation event
  }

data CoverageReport = CoverageReport
  { requiredCells :: [BehaviorKey]
  , requiredTransitions :: [BehaviorKey]
  , missing :: [BehaviorKey]
  , duplicate :: [BehaviorKey]
  , stale :: [BehaviorKey]
  }
```

The generated aggregate harness must expose a function equivalent to
`runBehaviorWitness :: BehaviorWitness Command Event -> Either ConformanceFailure ()` and a
complete `behaviorWitnesses` value imported from consumer-owned `Holes.hs`. Use the existing Keiki
transducer and generated event codec for replay; do not implement a second transition evaluator.
The report JSON is a versioned public CLI contract and must be represented in scaffold/workspace
records before enforcement.


Revision note: Detached this plan from the completed structural-consumer-type MasterPlan so it is
an independent implementation unit, 2026-07-31.
