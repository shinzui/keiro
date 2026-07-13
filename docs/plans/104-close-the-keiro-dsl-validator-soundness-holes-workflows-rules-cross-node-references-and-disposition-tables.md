---
id: 104
slug: close-the-keiro-dsl-validator-soundness-holes-workflows-rules-cross-node-references-and-disposition-tables
title: "Close the keiro-dsl validator soundness holes: workflows, rules, cross-node references, and disposition tables"
kind: exec-plan
created_at: 2026-07-13T18:56:58Z
intention: "intention_01kxed7haee7ja78qm70cc6qm5"
master_plan: "docs/masterplans/15-harden-and-extend-the-keiro-dsl-toolchain-surfaced-by-the-2026-07-dsl-audit.md"
---

# Close the keiro-dsl validator soundness holes: workflows, rules, cross-node references, and disposition tables

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`keiro-dsl check` is the gate that is supposed to reject a dangerous-by-omission `.keiro`
specification before any Haskell is written. Today that gate has large holes: a workflow
node receives zero validation (duplicate body labels — which corrupt deterministic replay —
pass silently), rule bodies escape the clock-free and scope checks that guards are subject
to, a process manager can dispatch a command its target aggregate never declared, a
workqueue disposition table can silently drop its poison-message row or shadow a safe row
with a dangerous duplicate, an intake can accept an event its topic never carries, a
projection status-map is "total" as long as its keys are accidental suffixes of event
names, and the workqueue's captured physical/dlq/table fixture trio is only one-third
checked (with a derivation that does not even match the live runtime's algorithm).

After this plan, every one of those specs fails `keiro-dsl check` with a precise,
row-anchored, machine-matchable diagnostic, and the specs that are actually safe still pass.
Concretely: a user who deletes the `decodeFailure -> deadLetter` row from a workqueue, or
writes two `duplicate =>` rows in an intake, or gives two workflow steps the same label,
or points `schedule` at a timer that does not exist, sees a non-zero exit and an error
naming the exact line — instead of a green check followed by a runtime that retries poison
forever, replays the wrong journal entry, or halts. Every new rule ships with a committed
failing fixture (a spec that violates it and passes `check` today with exit 0) and a
passing counterpart, wired into `keiro-dsl/test/Main.hs` in the existing per-rule style.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] (2026-07-13 20:29Z) M1: add `Loc` to `StateDecl`, `DispositionRow`, `WqDispRow`, `DispatchNode`, `EmitMapRow`, and the four `WfBodyItem` constructors in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`.
- [x] (2026-07-13 20:29Z) M1: populate the new locations in `keiro-dsl/src/Keiro/Dsl/Parser.hs`; update pattern matches in `PrettyPrint.hs`, `Validate.hs`, `Harness.hs`; update `genState` in `test/Main.hs`.
- [x] (2026-07-13 20:29Z) M1: fix the `ProcessFireAtNotInjected` double-fire in `Validate.hs` and re-anchor `UnreachableState` and per-dispatch diagnostics to their rows; disposition-row anchoring will be exercised when M5 adds duplicate-row diagnostics.
- [x] (2026-07-13 20:29Z) M1: round-trip property, 94-example unit suite, aggregate conformance pin, and workflow conformance pin all green.
- [x] (2026-07-13 20:32Z) M2: spec-level duplicate detection (nodes, enum ctors/wires, id prefixes, command/event names) with fixture `duplicate-names.keiro`.
- [x] (2026-07-13 20:32Z) M2: aggregate-local reference soundness (write targets, `fields(Cmd)` resolution, `regInitial` scope) with fixture `aggregate-bad-refs.keiro`; 96-example unit suite green.
- [ ] M3: `validateWorkflow` (duplicate labels, sleep-delay resolution, `id from input.<field>` resolution) with fixtures `workflow-dup-label.keiro`, `workflow-unresolved-fields.keiro`.
- [ ] M3: rule validation (domain resolution, totality, dangling cases, clock-free + scoped bodies) with fixtures `rule-bad-domain.keiro`, `rule-not-total.keiro`.
- [ ] M3: operation validation (CommandOp aggregate/stream-field/projections, SignalOp value type, QueryOp deferral stub) with fixtures `operation-ghost-aggregate.keiro`, `operation-signal-value.keiro`; update `workflow.keiro` and `workflow-signal-mismatch.keiro`.
- [ ] M4: process cross-node resolution (advance/dispatch/fire commands, target-side field bindings, `schedule` = timer name, projections, advance-arm dispatch-id, `max-attempts >= 1`) with fixtures `process-ghost-refs.keiro`, `process-bad-timer.keiro`.
- [ ] M4: update `hospital-surge.keiro`, `surge-service.keiro`, and the `process` skeleton in `Skeleton.hs` so the canonical corpus resolves.
- [ ] M5: workqueue disposition completeness + duplicate-row detection in both intake and workqueue tables, with fixtures `workqueue-incomplete.keiro`, `workqueue-dup-row.keiro`, `intake-dup-row.keiro`.
- [ ] M5: topic affinity both directions with fixtures `intake-topic-mismatch.keiro`, `emit-topic-mismatch.keiro`.
- [ ] M5: exact status-map matching + dangling-key + duplicate-key diagnostics; update all fixture status-maps to full event names; fixtures `statusmap-dangling.keiro`, `statusmap-dup-key.keiro`; conformance pin still byte-stable.
- [ ] M5: faithful queueRef re-derivation (sanitize/collapse/hash) + dlq + table checks with fixtures `workqueue-dlq-divergent.keiro`, `workqueue-table-divergent.keiro`, `workqueue-uppercase-logical.keiro` (false-positive removal), `workqueue-hashed-logical.keiro`; live cross-check added to the `keiro-dsl-conformance-queue-runtime` suite.
- [ ] M5: PgmqDispatch dedup-queue and dedup-queue-field resolution with fixtures `dispatch-dedup-ghost-queue.keiro`, `dispatch-dedup-bad-field.keiro`; read-model arms deferred via the documented stub.
- [ ] M6: true-up the two false claims in `agents/skills/keiro-dsl-authoring/NOTATION.md`; final full-suite run (unit + all 17 conformance suites); living sections updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- (Drafting, 2026-07-13) The validator's existing "physical name" re-derivation
  (`Validate.hs:162-163`) is not merely incomplete (dlq/table unchecked) — it is a
  different algorithm from the live `Keiro.PGMQ.Runtime.queueRef`. It maps every
  non-`[a-z0-9_]` character to `_` without lower-casing, collapsing underscores,
  forcing a leading letter, or applying the 43-character hash fallback. A logical name
  `"Repro.Work"` derives `"repro_work"` at runtime but the validator "expects"
  `"_epro__ork"` and reports a false `WqPhysicalDivergence`. M5 therefore fixes a false
  positive as well as adding the two missing checks.
- (Drafting, 2026-07-13) The canonical process fixtures (`test/fixtures/hospital-surge.keiro`
  and the `process` skeleton in `Skeleton.hs:111-118`) dispatch commands
  (`NoteSurgeThreshold`, `ActivateSurge`, `MarkSurgeTimerFired`) that their aggregates
  never declare — the aggregates are bare `regs`/`states` stubs. Command-resolution (M4)
  forces these fixtures to finally declare the commands they dispatch, which incidentally
  removes the pinned-green "empty aggregate" examples from the DSL's own corpus (the
  general empty-aggregate rule remains owned by docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md).
- (Drafting, 2026-07-13) Moving the status-map to exact event-name matching does not
  change any committed generated module: a full event name is a suffix of itself, so the
  scaffolder's current suffix lowering produces byte-identical output once the fixture
  keys are spelled in full. The validator and the fixtures can move first; the scaffold
  lowering moves in plan 106 with zero conformance churn.
- (Implementation, 2026-07-13) `cabal build keiro-dsl` is ambiguous because the
  package exposes both a library and an executable with that name. The milestone build
  command is therefore `cabal build lib:keiro-dsl`; the unit and conformance target
  names remain unambiguous. Evidence: Cabal reported `exe:keiro-dsl` and
  `lib:keiro-dsl` as the two candidates, while `cabal build lib:keiro-dsl` completed.


## Decision Log

Record every decision made while working on the plan.

- Decision: Workflow body labels must be unique across ALL item kinds (step, await,
  sleep, child) within one workflow, not merely within a kind.
  Rationale: replay is keyed by step name, not source position
  (`keiro/src/Keiro/Workflow.hs:24-26`), and a same-kind duplicate makes the second
  occurrence replay the first's journaled result — silent corruption. Cross-kind
  collisions are technically disambiguated at runtime by reserved step-name prefixes
  (`keiro/src/Keiro/Workflow/Types.hs:171-176`), but await labels are also the
  signal-targeting namespace (`Validate.hs` matches `signal <label>` against await
  labels), so allowing a `step` and an `await` to share a label invites exactly the
  ambiguity the notation promises not to have ("Replay matches on the label",
  `Grammar.hs:739-740`). One uniform rule is simpler to author against and strictly safer.
  Date: 2026-07-13.
- Decision: The NOTATION.md-claimed "child id MUST differ from parent's" check is NOT
  implementable spec-side, and the claim is removed rather than implemented.
  Rationale: `WfChild` carries only a label, an opaque via-function name, and a result
  type (`Grammar.hs:743-751`); the child's id is computed at runtime by a hand-filled
  hole from the child's input. There is no value in the spec to compare against the
  parent's id derivation. The obligation is real (a child id equal to the parent's
  collides on the journal stream) but it belongs in the generated hole documentation —
  the holistic skill refresh in docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md.
  This plan makes the minimal NOTATION.md edit (M6).
  Date: 2026-07-13.
- Decision: Rule-case bodies are scope-checked against enum constructors and boolean
  literals only (no registers, no command fields, no other rules), and clock-checked
  against the same `clockAtoms` set as guards.
  Rationale: a rule (`Grammar.hs:153-160`) is declared as a total function from an enum,
  independent of any aggregate; registers and command fields have no meaning in its body,
  and allowing rule-to-rule references would admit recursion the scaffold cannot lower.
  Reusing `GuardAtomOutOfScope` and `ClockSampled` keeps the diagnostic vocabulary small.
  Date: 2026-07-13.
- Decision: Process field bindings are resolved target-side only: every binding name in
  an `advance`/`dispatch`/`fire` block must be a declared field of the target command.
  Source-side resolution (does the VALUE exist?) is NOT attempted.
  Rationale: the source vocabulary differs per arm — `advance`/`dispatch` bare bindings
  draw from the process input, but `fire` bare bindings draw from the timer payload and
  the timer's own identity (`timerId`), and `=value` bindings are opaque dotted
  references (`timer.id`, `input.x`). A sound source-side rule needs a modeled
  binding-source vocabulary, which is out of scope; target-side resolution alone already
  catches the audited hole (bindings against undeclared command fields).
  Date: 2026-07-13.
- Decision: `procProjections` and a CommandOp's `project [...]` list resolve against the
  union of declared aggregate projection tables (`projTable` of every aggregate's
  `projection` clause) in the same spec.
  Rationale: that is the only projection-table namespace the grammar declares today.
  docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md
  adds a `readmodel` node; when it lands, resolution extends to readmodel names (see
  Interfaces and Dependencies). Fixtures that name phantom projections are updated:
  `hospital-surge.keiro` and the `process` skeleton move to `projections [ ]`;
  `surge-service.keiro` (which declares real projections) becomes the positive case.
  Date: 2026-07-13.
- Decision: A CommandOp's `stream from <field>` must name a field of at least one
  declared command of the target aggregate.
  Rationale: the operation has no input declaration of its own, so the only declared
  namespace the stream key can come from is the aggregate's command fields; requiring
  membership in at least one command catches the "field from nowhere" hole without
  over-constraining which command the hole fill will use.
  Date: 2026-07-13.
- Decision: QueryOp read-model resolution (and the PgmqDispatch `pdSourceReadModel` /
  `pdDedupReadModel` / read-model field / source-key arms) is explicitly DEFERRED behind
  a single documented stub, `resolveReadModelRef`, that returns no diagnostics today.
  Rationale: there is nothing in the grammar for a `query <ReadModel>` to resolve
  against (audit finding E1); inventing a partial rule against projection tables would
  produce false positives for read models that legitimately live outside the spec until
  the `readmodel` node exists. Plan 107 completes the stub. QueryOp's other clauses
  (input/result/consistency types) are open vocabulary and stay unchecked here.
  Date: 2026-07-13.
- Decision: The required workqueue disposition outcome set is
  `{storeFailure, commandRejected, decodeFailure, onCodecReject}`; extra author-defined
  rows are allowed; duplicate rows (same outcome twice) are an error in BOTH the intake
  and workqueue tables.
  Rationale: the generated `jobOutcomeFor :: Text -> JobOutcome` maps these four
  spec-named outcomes onto the live `Keiro.PGMQ.Job.JobOutcome` codomain
  (`Done | Retry | RetryDefault | Dead`, `keiro-pgmq/src/Keiro/PGMQ/Job.hs:170-179`)
  and ends with a catch-all `_ -> Retry ...` (`Scaffold.hs:629-633`), so an absent
  `decodeFailure` row silently RETRIES POISON — the exact inversion the intake's
  `DispositionIncomplete` exists to prevent. Unlike the intake's seven outcomes, the
  workqueue vocabulary is an authoring convention (the handler may emit bespoke
  outcomes), so extra rows stay legal; but the four canonical hazard rows must be
  present, and a duplicate row is always an error because first-wins `lookup` lets a
  duplicate shadow the row the inversion checks inspect.
  Date: 2026-07-13.
- Decision: Status-map matching semantics (shared with the scaffold): a key covers an
  event if and only if it is exactly, case-sensitively equal to the full event name;
  a key equal to no event name is an error (`StatusMapDanglingKey`); a key appearing
  more than once is an error (`StatusMapDuplicateKey`); totality (`StatusMapNotTotal`)
  is computed over exact coverage, still suppressed by `mapPartial`.
  Rationale: `T.isSuffixOf` (`Validate.hs:448`) is trivially satisfiable (`d => held`
  is "total") and the scaffold's first-match suffix lowering
  (`Scaffold.hs:1148-1151`) mis-lowers `ReservationUnHeld` to `"held"` under a
  `{ Held => held, UnHeld => available }` map. The scaffold side is owned by plan 106;
  both plans state these identical semantics, and whichever lands second must verify
  against the other's fixtures (this plan's: `statusmap-dangling.keiro`,
  `statusmap-dup-key.keiro`, and the updated full-name `reservation.keiro`).
  The unwritable-`mapPartial` syntax problem (audit C2) is owned by
  docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md;
  this plan keeps reading `mapPartial` as-is.
  Date: 2026-07-13.
- Decision: `regInitial` scope rule: if the register's type names a declared enum, the
  initial must be a constructor of THAT enum; if the type is the aggregate's implicit
  vertex type (`<AggName>Vertex`), the initial must be a declared state; if the type
  names a declared id, the initial must be the literal `placeholder`; any other type
  (e.g. `Text`) is left unchecked.
  Rationale: these are exactly the three shapes the corpus uses
  (`test/fixtures/reservation.keiro` regs block); text-register initials are a scaffold
  problem (audit D8) owned by plan 106.
  Date: 2026-07-13.
- Decision: The queueRef re-derivation is REIMPLEMENTED as pure functions inside
  `Keiro.Dsl.Validate` (exported as `derivedQueueTrio :: Text -> (Text, Text, Text)`),
  not imported from keiro-pgmq; anti-drift is enforced by a new cross-check in the
  existing `keiro-dsl-conformance-queue-runtime` test suite (which already depends on
  keiro-pgmq) asserting `derivedQueueTrio` equals the live `queueRef` over a vector
  list including dotted, upper-cased, illegal-character, over-43-character, and
  `_dlq`-suffixed logical names.
  Rationale: the keiro-dsl library is a pure parser/validator tool
  (build-depends: base, containers, megaparsec, parser-combinators, prettyprinter,
  text — `keiro-dsl.cabal:43-49`); depending on keiro-pgmq would drag hasql/pgmq into
  it. The conformance suite is the established place where keiro-dsl output is proven
  against live runtimes.
  Date: 2026-07-13.
- Decision: Empty-aggregate rejection stays with plan 106 (it is a scaffold-output
  hazard, audit D4); this plan does not add a validator rule for it. M4's command
  resolution independently forces the process corpus to declare its commands, so the
  overlap is corpus-level only, not rule-level.
  Date: 2026-07-13.
- Decision: New `DiagnosticCode` constructors are appended in one block at the end of
  the existing enum, in the order listed under Interfaces and Dependencies. Plans
  107/108/109 append their node-specific codes AFTER this block and must not rename any
  of these.
  Date: 2026-07-13.
- Decision: Per-row `Loc` additions are bounded to `StateDecl`, `DispositionRow`,
  `WqDispRow`, `DispatchNode`, `EmitMapRow`, and the `WfBodyItem` constructors. The
  status-map `Mapping` pairs and rule cases keep anchoring at their block/decl line.
  Rationale: these six are the rows the new rules diagnose per-row; `Mapping` pairs are
  `[(Name, Name)]` used by both validator and scaffold, and restructuring them is
  churn plan 105/106 does not need. `Loc`'s `Eq` deliberately ignores the line value
  (`Grammar.hs:119-123`: `instance Eq Loc where _ == _ = True` — verified), so the
  `parse . pretty` round-trip property is unaffected by carrying locations the printer
  does not reproduce.
  Date: 2026-07-13.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Standing assumption: keiro MasterPlan 14
(docs/masterplans/14-harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review.md)
is implemented first. This MasterPlan (MP-15) changes ONLY the `keiro-dsl` package, its
tests, the authoring skill under `agents/skills/keiro-dsl-authoring/`, and docs — never
`keiro`/`keiro-core`/`keiro-pgmq` runtime code. Runtime sources are cited below strictly
as read-only ground truth for what the validator must mirror.

keiro-dsl is a typed-specification toolchain: an author writes a `.keiro` file describing
a keiro service (aggregates, process managers, Kafka contracts/intakes/emits, pgmq
workqueues/dispatches, durable workflows/operations), runs `keiro-dsl check` to validate
it, and `keiro-dsl scaffold` to emit a deterministic generated layer plus typed holes.
The pieces this plan touches, all under `keiro-dsl/`:

- `src/Keiro/Dsl/Grammar.hs` (834 lines) — the AST. `Loc` is a newtype over `Int` whose
  `Eq` ignores the value (lines 119-127), attached to declarations so diagnostics carry
  line numbers. Node families: `Aggregate`, `ProcessNode` (+ nested `TimerNode`,
  `HandleNode`, `AdvanceNode`, `DispatchNode`, `FireNode`), `ContractNode`, `IntakeNode`,
  `EmitNode`, `PublisherNode`, `WorkqueueNode`, `PgmqDispatchNode`, `WorkflowNode`
  (`WfBodyItem` at lines 739-751: `WfStep`/`WfAwait`/`WfSleep`/`WfChild`, positional),
  `OperationNode` (`OperationShape` at 771-780: `CommandOp`/`QueryOp`/`SignalOp`/`RunOp`).
  Shared declarations: `IdDecl`, `EnumDecl`, `RuleDecl` (153-160: name, domain enum,
  codomain, `[(ctor, Expr)]` cases).
- `src/Keiro/Dsl/Parser.hs` (1178 lines) — megaparsec parser. `getLoc` (157-158) reads
  the current source line. Row parsers relevant here: `pStateDecl` (342-346),
  `pDispositionRow` (581-585), `pWqDispRow` (728-732), `pDispatch` (958-971),
  `pMapRow` (634-638), `pWfBodyItem` (811-820).
- `src/Keiro/Dsl/PrettyPrint.hs` (495 lines) — renders a `Spec` back to text;
  `parse . pretty` must round-trip to an `Eq`-equal AST. Positional `WfBodyItem`
  patterns at lines 91-94 are the only pretty-printer code that pattern-matches a type
  gaining a `Loc`.
- `src/Keiro/Dsl/Validate.hs` (511 lines) — THE FILE THIS PLAN IS ABOUT. `validateSpec`
  (110-112) concat-maps `validateNode` over `specNodes` — nothing validates spec-level
  properties (duplicates, rules). Current per-node state, with the holes marked:
  `NWorkflow` returns `[]` outright (line 123). `validateOperation` (131-146) checks
  only SignalOp label matching and RunOp workflow resolution; `CommandOp`/`QueryOp`
  fall into `_ -> []` (line 146). `validateWorkqueue` (157-182) re-derives only the
  physical name, with a naive character map (162-163) that diverges from the live
  algorithm, and checks two inversions via first-wins `lookup` (169). `validatePgmqDispatch`
  (185-189) resolves only `pdEnqueueTo`. `intakeCoupling` (196-209) resolves contract,
  topic and accepted events but never checks that an accepted event's declared topic
  equals the intake's topic. `validateEmit` (211-228) has the mirror hole.
  `validateIntake` (239-267) has completeness over seven outcomes plus three inversions,
  all via first-wins `lookup` (244) — a duplicate row shadows the checked one.
  `validateProcess` (270-331): `noWallClock` (283-292) double-fires for one unknown
  field (the second guard's population subsumes the first); `runtimeOwnedDispatchId`
  (296-307) covers `dispatch` and `fire` arms but not `advance`; `crossNodeCoupling`
  (310-319) resolves saga/target/fire-target aggregate NAMES only — never
  `advCommand`/`dispCommand`/`fireCommand` against the target's declared commands,
  never field bindings, never `hSchedule` against the timer name, never
  `procProjections`; `tmMaxAttempts` has no range check (contrast `WqDlqWithoutCeiling`,
  179-182). `validateAggregate` (333-491): guard/write scope check inspects only the
  atoms of expressions — `map snd (tWrites t)` at 415 — so the write TARGET is never
  checked; `evBody`'s `EventFromCommand` is never resolved; `regInitial` is never
  scope-checked; status-map totality uses `T.isSuffixOf` (448). `specRules` are
  harvested only for their names (352), so rule bodies escape the clock-free and scope
  rules entirely, rule totality is unchecked, and `ruleDomain` never resolves.
  `DiagnosticCode` (32-73) is the machine-matchable code registry tests match on.
- `src/Keiro/Dsl/Scaffold.hs`, `src/Keiro/Dsl/Harness.hs` — consumers whose pattern
  matches change when `WfBodyItem` gains a `Loc` (`Harness.hs:148-156,189`) and whose
  status-map lowering (`Scaffold.hs:1141-1155`, suffix first-match at 1148-1151) must
  eventually match the validator's exact semantics (owned by plan 106; see Decision Log).
  The generated workqueue policy (`Scaffold.hs:609-638`) is the ground truth for why
  workqueue completeness matters: `jobOutcomeFor` ends in `_ -> Retry (RetryDelay …)`
  (633), so any outcome the table omits silently retries.
- `src/Keiro/Dsl/Skeleton.hs` — the `new <kind>` starter specs; a test pins every
  skeleton to validate with zero errors (`test/Main.hs:273-275`), so skeletons must be
  updated in lockstep with new rules (M4).
- `test/Main.hs` (570 lines) — hspec driver. The per-rule convention this plan follows
  (lines 49-67 and siblings): a fixture under `test/fixtures/<name>.keiro`, loaded via
  `diagnosticCodesOf` (all codes) or `errorCodesOf` (Error severity only, 342-347), and
  an assertion `codes \`shouldContain\` [TheCode]` for failing fixtures or
  `codes \`shouldBe\` []` for passing ones. The `parse . pretty` round-trip property
  (24-27) generates only aggregate nodes (`genSpec`, 554-563); `genState` (486)
  constructs `StateDecl` applicatively and needs a `pure noLoc` when the type gains a
  location. The scaffold pin test (319-321 + `assertMatchesCommitted`) compares fresh
  scaffold output to committed conformance modules — the M5 fixture edits must keep it
  byte-stable (they do; see Surprises & Discoveries). NOTE: the unit suite reads fixture
  paths relative to the package directory, so all test commands below run from
  `keiro-dsl/` (audit C8; the cwd fix itself is owned by plan 105).
- `app/Main.hs` — the CLI. `check` (49-51) prints diagnostics via `renderDiagnostic`
  (`<file>:<line>: error[<Code>]: <message>`) to stderr and exits non-zero on any
  Error-severity diagnostic.

Runtime ground truth this plan mirrors (read-only):

- Workflow replay identity: "Replay is keyed by step name, not by source position or
  code identity" (`keiro/src/Keiro/Workflow.hs:24-26`). The journal event is
  `StepRecorded {stepName, result, recordedAt}` (`keiro/src/Keiro/Workflow/Types.hs:192`);
  sleep/awakeable/child completions journal as `StepRecorded` under reserved step-name
  prefixes (`Types.hs:171-176`). Therefore two body items with the same label journal
  under the same step name: on resume, the second one replays the FIRST one's recorded
  result instead of running. This is the concrete replay hazard behind
  `WorkflowDuplicateLabel`.
- Queue naming: `Keiro.PGMQ.Runtime.queueRef :: Text -> QueueRef`
  (`keiro-pgmq/src/Keiro/PGMQ/Runtime.hs:94-166`) derives the physical name by
  lower-casing, mapping every non-`[a-z0-9_]` character to `_`, collapsing runs of
  underscores (trimming leading/trailing), guaranteeing a leading ASCII letter (prefix
  `q` otherwise, bare `q` for empty), and — when the sanitized base exceeds 43
  characters OR ends in `_dlq` — replacing it with
  `<first 26 chars of base, trailing underscores trimmed, "q" if empty>_<16-hex-char FNV-1a-64 of the FULL ORIGINAL logical name>`
  (offset `0xcbf29ce484222325`, prime `0x100000001b3`, zero-padded to 16 hex digits).
  The dlq name is `<physical>_dlq`. PGMQ stores each queue as the table
  `pgmq.q_<physical>` (`keiro-pgmq/src/Keiro/PGMQ/Metrics.hs:5`,
  `keiro-pgmq/src/Keiro/PGMQ/Dlq.hs:204`), so the expected `table` fixture is
  `"pgmq.q_" <> physical`. `pgmq-core` exposes `queueNameToText`
  (`Pgmq/Types.hs:81`) to unwrap `QueueName` in the cross-check test.
- Job outcomes: `JobOutcome = Done | Retry !RetryDelay | RetryDefault | Dead !Text`
  (`keiro-pgmq/src/Keiro/PGMQ/Job.hs:170-179`) is the codomain the generated
  `jobOutcomeFor` maps the spec's outcome rows onto.

Sibling-plan boundaries (reference sibling plans only by path):

- docs/plans/105-fix-keiro-dsl-notation-integrity-string-escaping-duplicate-clauses-numeric-bounds-and-identifier-hygiene.md
  owns Haskell-keyword/identifier hygiene, string escaping, duplicate `wire`/`projection`
  /`goto` CLAUSES (parser-level first-wins — distinct from this plan's duplicate NAMES),
  numeric bounds, and the `mapPartial` concrete syntax.
- docs/plans/106-harden-the-keiro-dsl-scaffolder-template-injection-firewall-completeness-collision-and-stale-module-detection-and-faithful-policy-lowering.md
  owns the scaffold side of status-map matching, empty-aggregate rejection, and
  case-variant/sanitization module-path collisions (this plan's duplicate rules operate
  on spec names only, exact-match).
- docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md
  completes read-model resolution (QueryOp, PgmqDispatch read-model arms, and extends
  projection-list resolution).
- docs/plans/110-align-keiro-dsl-with-the-safe-apis-and-refresh-the-authoring-skill-and-corpus.md
  owns the holistic skill refresh; this plan makes only the two minimal NOTATION.md
  claim corrections.


## Plan of Work

The work is six milestones. Each lands compiling, with the full unit suite green from
`keiro-dsl/`, and each new rule lands together with its failing fixture, its passing
counterpart, and its `test/Main.hs` assertions. Effort is framed as complexity/risk:
M1 is mechanical but wide (many files touch one type change); M4 and M5 carry the real
design risk because they change what the canonical corpus must declare; M2/M3 are
self-contained rule additions; M6 is documentation and verification.

### Milestone 1 — Row-level locations and diagnostic-quality repairs (audit B12)

Goal: diagnostics point at the offending ROW, not the block header, and no rule fires
twice for one defect. This must land first because every later milestone anchors its new
diagnostics on these locations.

Work: in `keiro-dsl/src/Keiro/Dsl/Grammar.hs`, add a `Loc` field to `StateDecl`
(`stLoc`), `DispositionRow` (`drLoc`), `WqDispRow` (`wqdLoc`), `DispatchNode`
(`dispLoc`), `EmitMapRow` (`emrLoc`), and a trailing `!Loc` argument to each of the four
`WfBodyItem` constructors (they are positional; a trailing location keeps existing
pattern prefixes readable). `Loc`'s `Eq` ignores the value, so AST equality — and with it
the `parse . pretty` round-trip property — is unaffected. In
`keiro-dsl/src/Keiro/Dsl/Parser.hs`, capture `getLoc` at the start of `pStateDecl`
(inside its `try`, before `ident`), `pDispositionRow`, `pWqDispRow`, `pDispatch`,
`pMapRow`, and each alternative of `pWfBodyItem`. Update the pattern matches that now
carry an extra field: `PrettyPrint.hs:91-94` (`bodyItem` arms gain a wildcard),
`Validate.hs:151` (`awaitLabels`), `Harness.hs:148-156` and `:189` (workflow facts
tags), and `test/Main.hs:486` (`genState` gains `<*> pure noLoc`). `Scaffold.hs` and
`Diff.hs` use record accessors for the affected record types and need no edits beyond
what the compiler demands.

Then fix the two diagnostic-quality defects in `Validate.hs`. First, make the
`ProcessFireAtNotInjected` guards mutually exclusive (currently `noWallClock`,
283-292, emits BOTH "not a declared :Time field" and "not a field of input" when the
field is absent entirely): if `f` is not an input field, emit only the "not a field"
diagnostic; only if it IS an input field but not `:Time`-typed, emit the type
diagnostic. Second, re-anchor existing diagnostics onto the new locations:
`UnreachableState` moves from `aggLoc` to the state's own `stLoc`; the intake/workqueue
inversion and (M5's) duplicate diagnostics anchor on the offending row's `drLoc`/`wqdLoc`;
per-dispatch process diagnostics (`ProcessDispatchIdSupplied`, `ProcessBenignInversion`,
M4's resolution errors) anchor on `dispLoc`; emit-row diagnostics on `emrLoc`.

Result and proof: `cabal test keiro-dsl-test` (from `keiro-dsl/`) is green, including
the round-trip property. A new unit test asserts that a process spec whose `fireAt`
names a completely-unknown field yields EXACTLY ONE `ProcessFireAtNotInjected`
diagnostic, and another asserts that an unreachable state's diagnostic carries the
state row's line, not the aggregate header's.

### Milestone 2 — Spec-level duplicate detection and aggregate-local reference soundness (audit B9 + B8)

Goal: two things named the same thing, and references into namespaces that were never
declared, are errors.

Work, duplicates (B9): add a `specLevelRules :: Spec -> [Diagnostic]` pass invoked from
`validateSpec` alongside the per-node fold. It reports: two nodes of the SAME kind with
the same name (`DuplicateNodeName` — aggregates, processes, contracts, intakes, emits,
publishers, workqueues, dispatches, workflows, operations; contract names are node
names, so "duplicate contract names" is covered here); duplicate constructors within one
enum (`DuplicateEnumCtor`) and duplicate wire spellings within one enum
(`DuplicateEnumWire`); duplicate `prefix=` values across `id` declarations
(`DuplicateIdPrefix`). Inside `validateAggregate`, report duplicate command names
(`DuplicateCommandName`) and duplicate event names (`DuplicateEventName`) within the
aggregate. Case-variant names that sanitize to the same module path are explicitly NOT
this plan's concern (scaffold-side, plan 106); these rules compare spec names exactly.

Work, aggregate-local references (B8): in `transitionScope`/new code in
`validateAggregate`: (1) every write TARGET — `fst` of each `tWrites` pair — must be a
declared register (`WriteTargetNotRegister`; note the current scope rule union includes
state names as legitimate ATOMS, but a write target is a register, full stop); (2) an
event body `EventFromCommand c` must resolve `c` against the aggregate's declared
commands (reuse `UndeclaredCommand` with an event-specific message — this also closes
the diff-side blind spot where `fields(NoSuchCommand)` makes the event look field-free);
(3) `regInitial` per the Decision Log rule (`RegisterInitialOutOfScope`).

Failing fixture `test/fixtures/duplicate-names.keiro` (passes `check` with exit 0
today; every construct below parses against the current grammar):

```text
context repro

id ThingId prefix=thing
id OtherId prefix=thing

enum Color { Red=red Red=crimson Green=red }

aggregate Thing
  regs
  states Idle

  command DoThing { thingId }
  command DoThing { otherId }
  event ThingDone { thingId }
  event ThingDone { otherId }

aggregate Thing
  regs
  states Idle
```

Expected after: `DuplicateIdPrefix` (thing), `DuplicateEnumCtor` (Red),
`DuplicateEnumWire` (red), `DuplicateCommandName` (DoThing), `DuplicateEventName`
(ThingDone), `DuplicateNodeName` (aggregate Thing).

Failing fixture `test/fixtures/aggregate-bad-refs.keiro` (exit 0 today):

```text
context repro

enum Color { Red=red Green=green }

aggregate Thing
  regs
    tint Color = NotAColor
    thingState ThingVertex = Pending
  states Pending Done!

  command DoThing { thingId }
  event ThingDone = fields(NoSuchCommand)

  Pending -- DoThing -->
    write ghostRegister := Done
    emit ThingDone
    goto Done

  wire kind=ctorName fields=camelCase schemaVersion=1
```

Expected after: `RegisterInitialOutOfScope` (NotAColor is no constructor of Color),
`UndeclaredCommand` (fields(NoSuchCommand)), `WriteTargetNotRegister` (ghostRegister).
Passing counterparts: the updated `reservation.keiro` and the `aggregate` skeleton
(both already conform to every M2 rule).

### Milestone 3 — Workflow, rule, and operation validation (audit B1 + B2 + B4)

Goal: the three node families with zero or token validation get real rules.

Work, workflows (B1): replace `validateNode _ (NWorkflow _) = []` (`Validate.hs:123`)
with `validateWorkflow`: (1) `WorkflowDuplicateLabel` — labels must be unique across
all body items (see Decision Log for the replay grounding; the message must say WHY:
"labels key deterministic replay; a duplicate label replays the first occurrence's
journaled result"); (2) `WorkflowSleepDelayUnresolved` — a `sleep <label> after <field>`
delay field must be a declared field of the workflow's input (`wfInputFields`); the
field's TYPE is not constrained (input-field types are open vocabulary); (3)
`WorkflowIdFieldUnresolved` — `id from input.<field>` (`wfIdField = Just f`) must
resolve against `wfInputFields`; `id from input` (whole-input, `Nothing`) is exempt.
The child-id check claimed by NOTATION.md is NOT implemented (Decision Log); M6 removes
the claim.

Work, rules (B2): add a rules pass (spec-level, since rules are top-level declarations
never visited today — `Validate.hs:352` only harvests names): (1) `RuleDomainUnresolved`
— `ruleDomain` must name a declared enum; when it does not, the dependent checks below
are skipped for that rule; (2) `RuleNotTotal` — every constructor of the domain enum
must appear as a case key; (3) `RuleCaseUnknownCtor` — every case key must be a
constructor of the domain enum (a dangling case is dead and usually a typo); (4) rule
case bodies run through the SAME expression checks as guards: `ClockSampled` for any
`clockAtoms` member (`ex RedTag => now` is a working bypass of the guard clock rule
today) and `GuardAtomOutOfScope` for atoms that are neither enum constructors nor
boolean literals (Decision Log scope).

Work, operations (B4): extend `validateOperation` beyond `Validate.hs:146`'s `_ -> []`:
(1) CommandOp — the `on <Agg>` aggregate must resolve to a declared aggregate
(`OperationUnresolvedRef`); when it resolves, `stream from <field>` must be a field of
at least one of that aggregate's commands (`OperationUnresolvedRef`) and each
`project [ ... ]` entry must resolve against the spec's declared projection tables
(`OperationUnresolvedRef`; extended to readmodel nodes by plan 107); (2) SignalOp — in
addition to the existing label match, the `value <T>` type must equal the matched
`await`'s result type (`AwaitSignalValueMismatch`; a mismatched payload type decodes to
garbage at the awakeable); (3) QueryOp — call the documented deferral stub
`resolveReadModelRef` (returns `[]` today; see Interfaces and Dependencies).

Failing fixture `test/fixtures/workflow-dup-label.keiro` (exit 0 today —
`NWorkflow` is unvalidated):

```text
context repro

workflow Dupes
  name "dupes"
  in DupInput { orderId:Id }
  out DupSummary
  id from input.orderId via idText
  body
    step do-work -> StepResult
    await do-work -> ApprovalResult
```

Expected after: `WorkflowDuplicateLabel` (do-work). Failing fixture
`test/fixtures/workflow-unresolved-fields.keiro` (exit 0 today):

```text
context repro

workflow Loose
  name "loose"
  in LooseInput { orderId:Id }
  out LooseSummary
  id from input.missingField via idText
  body
    step do-work -> StepResult
    sleep cool-off after missingDelay
```

Expected after: `WorkflowIdFieldUnresolved` (missingField),
`WorkflowSleepDelayUnresolved` (missingDelay).

Failing fixture `test/fixtures/rule-not-total.keiro` (exit 0 today — rule bodies are
never visited):

```text
context repro

enum Color { Red=red Green=green }

rule isHot : Color -> Bool
  ex Red => now ; Blue => true
```

Expected after: `RuleNotTotal` (Green uncovered), `RuleCaseUnknownCtor` (Blue),
`ClockSampled` (now). Failing fixture `test/fixtures/rule-bad-domain.keiro` — the same
rule with `Temperature` as the domain and no such enum — expects `RuleDomainUnresolved`
only (dependent checks skipped).

Failing fixture `test/fixtures/operation-ghost-aggregate.keiro` (exit 0 today —
CommandOp is unvalidated):

```text
context repro

workflow Wf
  name "wf"
  in WfInput { thingId:Id }
  out WfSummary
  id from input.thingId via idText
  body
    await approval -> ApprovalResult

operation DoThing
  command on GhostAggregate
    stream from thingId via thingStream
    project [ ghostTable ]
```

Expected after: `OperationUnresolvedRef` (GhostAggregate; the stream-field and
projection checks are skipped when the aggregate itself is unresolved, but `ghostTable`
still fails projection-table resolution — assert `shouldContain [OperationUnresolvedRef]`).
Failing fixture `test/fixtures/operation-signal-value.keiro` — the workflow above plus:

```text
operation SignalApproval
  signal approval of Wf
    key from thingId via wfId
    value WrongType
```

Expected after: `AwaitSignalValueMismatch` (WrongType vs ApprovalResult). Both parse
and pass today (the label `approval` matches, so no `AwaitSignalMismatch` fires).

Fixture updates: `test/fixtures/workflow.keiro` currently says `command on Reservation
… project [ transferDecision ]` with NO `Reservation` aggregate in the file — it fails
the new CommandOp rules. Append a minimal resolving aggregate to it (and identically to
`workflow-signal-mismatch.keiro`, whose test asserts `shouldContain
[AwaitSignalMismatch]` and must not accumulate unrelated errors):

```text
aggregate Reservation
  regs
    reservationState ReservationVertex = Open
  states Open Confirmed!

  command ConfirmTransfer { reservationId }
  event TransferConfirmed = fields(ConfirmTransfer)

  Open -- ConfirmTransfer --> write reservationState := Confirmed ; emit TransferConfirmed ; goto Confirmed

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection transferDecision consistency=Strong key=reservationId
    status-map { TransferConfirmed=>confirmed }
```

`stream from reservationId` resolves (field of ConfirmTransfer), `project
[ transferDecision ]` resolves (declared projection table), and the status-map key is
already spelled in full for M5. The `query transferDecision` operation in the same
fixture stays green via the QueryOp deferral. The workflow skeleton in `Skeleton.hs`
contains no CommandOp/QueryOp and needs no change for M3.

Result and proof: the three new failing fixtures produce the listed codes; the updated
`workflow.keiro` and every skeleton still validate with zero errors; the full unit
suite is green.

### Milestone 4 — Process cross-node resolution (audit B3)

Goal: a process manager's dispatched/fired/advanced commands, its schedule reference,
its projections, and its timer ceiling all resolve or bound-check; the runtime-owned-id
rule covers the advance arm.

Work in `validateProcess`: (1) resolve `advCommand` against the SAGA aggregate's
declared commands, each `dispCommand` against its `dispTarget` aggregate's commands,
and `fireCommand` against the fire-target aggregate's commands (reuse
`ProcessUnresolvedRef`; skip the command check when the aggregate itself is unresolved
— that already errors); (2) target-side field-binding resolution
(`ProcessFieldBindingUnresolved`): every `FieldBinding` name in an
advance/dispatch/fire block must be a declared field of the resolved target command
(Decision Log: source-side resolution deliberately not attempted); (3) `hSchedule` must
equal the declared timer's name (`tmName (procTimer p)`) — reuse
`ProcessUnresolvedRef`; (4) every `procProjections` entry must resolve against the
spec's declared projection tables (reuse `ProcessUnresolvedRef`; plan 107 extends);
(5) extend `runtimeOwnedDispatchId` to the advance arm: an `advFields` binding named
`commandId` or `id` is `ProcessDispatchIdSupplied`; (6) `tmMaxAttempts >= 1`
(`ProcessTimerCeilingInvalid` — `max-attempts 0` currently passes although the
generated worker comment promises a real ceiling).

Corpus updates forced by (1)-(4) — `test/fixtures/hospital-surge.keiro` (and its
`-clock`/`-dispatchid`/`-badref` variants) plus the `process` skeleton in
`Skeleton.hs:77-118` currently dispatch commands their bare aggregates never declare
and name a phantom `hospitalReadiness` projection. Update all of them identically:
declare on `Surge` the commands `NoteSurgeThreshold { hospitalId availableIcuBeds:Int
redDemand:Int timerId }` and `MarkSurgeTimerFired { hospitalId timerId }`, on
`Hospital` the command `ActivateSurge { hospitalId }`, and change
`projections [ hospitalReadiness ]` to `projections [ ]` (the aggregates have no
events, so declaring a projection there would manufacture a new instance of the
empty-aggregate scaffold hazard owned by plan 106). `test/fixtures/surge-service.keiro`
already declares every dispatched command; change its `projections [ ]` to
`projections [ surge ]` so the corpus has a POSITIVE projections-resolution case
(its `surge` projection table is declared; the process scaffolder does not read
`procProjections`, so committed conformance output is unchanged — verify with the pin
test).

Failing fixture `test/fixtures/process-ghost-refs.keiro` (exit 0 today — only
aggregate NAMES are resolved). It is the skeleton shape with ghost references:

```text
context repro

process Demo
  name "demo"
  input DemoInput { thingId observedAt:Time }
  correlate input.thingId via idText
  saga Saga stream="demo-" <> correlationId
  target Target
  projections [ ghostReadiness ]

  on DemoInput
    advance GhostAdvance { thingId commandId=input.thingId }
    dispatch Target@input.thingId GhostCommand { thingId }
      on-appended AckOk ; on-duplicate Retry ; on-failed Retry
    schedule wrongTimer

  dispatch-id strategy=uuidv5 from=(name, correlationId, sourceEventId, emitIndex)

  timer demoTimer
    id uuidv5 "demo-timer:" <> correlationId
    fireAt input.observedAt + 5m
    payload { kind="demo" }
    fire dispatch Saga@correlationId GhostFire { thingId }
      fired-event-id uuidv5 "demo-fired:" <> correlationId
      on-ok Fired ; on-reject Retry ; on-error Retry ; not-mine Retry
    decode unknown-status => Cancelled
    max-attempts 5 dead-letter "ceiling"

aggregate Saga
  regs
  states Idle

aggregate Target
  regs
  states Ready
```

Expected after: `ProcessUnresolvedRef` for GhostAdvance, GhostCommand, GhostFire,
ghostReadiness, and wrongTimer (five distinct diagnostics), plus
`ProcessDispatchIdSupplied` for the advance-arm `commandId=` binding. A second failing
fixture `test/fixtures/process-bad-timer.keiro` — the updated hospital-surge shape with
`max-attempts 0` — expects `ProcessTimerCeilingInvalid`, and a field-binding variant
(dispatch `ActivateSurge { notAField }` against the now-declared command) expects
`ProcessFieldBindingUnresolved`. Passing counterparts: the updated
`hospital-surge.keiro`, `surge-service.keiro`, and the updated `process` skeleton
(pinned by the existing skeleton-validates-clean test).

Result and proof: new fixtures produce the listed codes; `errorCodesOf
"test/fixtures/hospital-surge.keiro"` is still `[]`; the process scaffold determinism
and `max-attempts = 5` tests still pass; the conformance pin is byte-stable.

### Milestone 5 — Disposition tables, topic affinity, status-map matching, the workqueue trio, and pgmq dispatch (audit B5 + B6 + B7 + B10 + B11)

Goal: the tables and captured fixtures that encode failure policy stop being defeatable.

Work, dispositions (B5): add workqueue completeness — every outcome in
`{storeFailure, commandRejected, decodeFailure, onCodecReject}` must have a row
(`WqDispositionIncomplete`; grounding in the Decision Log — the generated
`jobOutcomeFor` catch-all at `Scaffold.hs:633` silently retries any missing outcome,
including poison). Add duplicate-row detection to BOTH tables: an outcome appearing in
more than one row of an intake's or a workqueue's disposition table is
`DispositionDuplicateOutcome`, anchored on the second row's new `Loc` (the first-wins
`lookup`s at `Validate.hs:169` and `:244` mean a duplicate row shadows the row the
inversion rules inspect — the duplicate itself is the defect).

Work, topic affinity (B6): in `intakeCoupling`, when the contract resolves, each
accepted event's declared `ceTopic` must equal `inkTopic` (`TopicAffinityMismatch` —
the consumer subscribes to a topic the event is never published on and silently
receives nothing). In `validateEmit`, mirror: each mapped event's `ceTopic` must equal
`emTopic` (the producer would publish to the wrong topic).

Work, status-map (B7): replace the `T.isSuffixOf` coverage test (`Validate.hs:448`)
with exact, case-sensitive equality against full event names; add
`StatusMapDanglingKey` (a key equal to no event name) and `StatusMapDuplicateKey` (the
same key twice). `mapPartial` continues to suppress only `StatusMapNotTotal`.
INTEGRATION (restated from the Decision Log): the scaffold lowers the same map with the
same suffix-first-match logic at `Scaffold.hs:1148-1151`; plan 106 owns that side; the
agreed semantics are identical — exact match on the full event name — and whichever
plan lands second verifies against the other's fixtures. Update every fixture
status-map to full event names in the same commit: `reservation.keiro` and its
`-clock`/`-fieldadd`/`-bad-command`/`-v2`/`-v2-noupcast` variants
(`Created=>held Confirmed=>confirmed` becomes
`TransferReservationCreated=>held TransferReservationConfirmed=>confirmed`),
`subscription.keiro` (`SubscriptionActivated=>active SubscriptionCancelled=>cancelled`),
and `surge-service.keiro` (`SurgeThresholdNoted=>noted SurgeTimerFired=>fired` and
`SurgeActivated=>surging`). Because a full name is a suffix of itself and first-match
picks the same row, the committed conformance Projection modules are byte-identical —
the scaffold pin test proves it.

Work, workqueue trio (B10): replace the naive physical derivation with a faithful pure
reimplementation of `queueRef` (the exact algorithm is transcribed in Context and
Orientation), exported as `derivedQueueTrio :: Text -> (Text, Text, Text)` returning
(physical, dlq, table) where dlq is `physical <> "_dlq"` derived the runtime's way
(the hash fallback also fires when the sanitized base ends in `_dlq`) and table is
`"pgmq.q_" <> physical`. Check all three captured fixtures: keep
`WqPhysicalDivergence` for the physical name and add `WqDlqDivergence` and
`WqTableDivergence`. Anti-drift: extend the existing
`keiro-dsl-conformance-queue-runtime` test suite (which already build-depends on
`keiro-pgmq`; add `keiro-dsl` and `pgmq-core`) with a check that `derivedQueueTrio l`
equals `(queueNameToText (physicalName r), queueNameToText (dlqName r), "pgmq.q_" <>
queueNameToText (physicalName r))` for `r = queueRef l` over at least these vectors:
`"hospital_capacity.reservation_work"`, `"Repro.Work"`, `"a__b..c"`, `"9lives"`,
`"already_dlq"`, and the over-43-character
`"hospital_capacity.reservation_work.per_hospital_fifo_lane_assignments"` (expected
physical `hospital_capacity_reservat_757040df00976c33` — confirm this drafted value
against the live `queueRef` in the test itself before committing the fixture that
embeds it).

Work, pgmq dispatch (B11): `pdDedupQueue` must resolve to a declared workqueue
(`DispatchDedupQueueUnresolved`), and when it does, `pdDedupQueueField` must equal the
wire name (`wqfWire`) of one of that workqueue's payload fields
(`DispatchDedupFieldUnresolved` — this is the raw-SQL dedup-site column, the drift
hazard MP-8 called out). `pdSourceReadModel`, `pdDedupReadModel`,
`pdDedupReadModelField`, and the source/dedup key fields go through the same
`resolveReadModelRef` deferral stub as QueryOp (plan 107 completes both together).

Failing fixtures (all exit 0 today). `test/fixtures/workqueue-incomplete.keiro` — the
`reservation-work.keiro` block with the `decodeFailure -> deadLetter` row deleted;
expects `WqDispositionIncomplete`. `test/fixtures/workqueue-dup-row.keiro` — the same
block with the disposition:

```text
  disposition {
    storeFailure -> retry 5s
    storeFailure -> deadLetter
    commandRejected -> deadLetter
    decodeFailure -> deadLetter
    onCodecReject -> deadLetter
  }
```

(today the second `storeFailure` row is shadowed by first-wins lookup, so even the
inversion checker cannot see it); expects `DispositionDuplicateOutcome`.
`test/fixtures/intake-dup-row.keiro` — the `intake.keiro` disposition with
`duplicate => retry 5s` ADDED AFTER the existing `duplicate => ackOk` row (today the
retry row is shadowed and `DispositionDuplicateRetry` does not fire — the shadowing IS
the exploit); expects `DispositionDuplicateOutcome`.
`test/fixtures/intake-topic-mismatch.keiro` — a contract with two topics where the
intake's topic is `aEvents` but the accepted event is declared `on bEvents`:

```text
context repro

contract twoTopics {
  schemaVersion 1
  discriminator messageType
  topic aEvents "repro.a.events"
  topic bEvents "repro.b.events"
  event ThingHappened on bEvents {
    thingId: typeid "thing"
  }
}

intake thingInbox {
  contract twoTopics
  topic aEvents
  accept ThingHappened

  bind messageId from header "keiro-message-id" required cross-check body

  dedupe key messageId policy PreferIntegrationMessageId

  decode {
    envelope strict-required lenient-optional
    body strict schemaVersion == 1
  }

  disposition {
    processed => ackOk
    duplicate => ackOk
    inProgress => retry 5s
    previouslyFailed => deadLetter "prior failure"
    decodeFailed => deadLetter
    dedupeFailed => deadLetter
    storeFailed => retry 5s
  }
}
```

Expects `TopicAffinityMismatch`. `test/fixtures/emit-topic-mismatch.keiro` — the
mirror: an emit on `aEvents` mapping to an event declared `on bEvents`; expects
`TopicAffinityMismatch`. `test/fixtures/statusmap-dangling.keiro`:

```text
context repro

aggregate Reservation
  regs
    reservationState ReservationVertex = Open
  states Open Held UnHeld

  command HoldIt { reservationId }
  command UnholdIt { reservationId }
  event ReservationHeld = fields(HoldIt)
  event ReservationUnHeld = fields(UnholdIt)

  Open -- HoldIt --> write reservationState := Held ; emit ReservationHeld ; goto Held
  Held -- UnholdIt --> write reservationState := UnHeld ; emit ReservationUnHeld ; goto UnHeld

  wire kind=ctorName fields=camelCase schemaVersion=1
  projection reservations consistency=Eventual key=reservationId
    status-map { Held=>held UnHeld=>available }
```

Today this is "total" (`Held` is a suffix of BOTH event names — the very ambiguity that
makes the scaffold lower `ReservationUnHeld` to `"held"`); after, both keys are
`StatusMapDanglingKey` and the map is `StatusMapNotTotal`.
`test/fixtures/statusmap-dup-key.keiro` — a map with the same full-name key twice;
expects `StatusMapDuplicateKey`. `test/fixtures/workqueue-dlq-divergent.keiro` and
`workqueue-table-divergent.keiro` — the `reservation-work.keiro` block with
`dlq = "wrong_dlq"` / `table = "pgmq.q_wrong"` respectively (both unchecked today);
expect `WqDlqDivergence` / `WqTableDivergence`. PASSING fixture
`workqueue-uppercase-logical.keiro` — logical `"Repro.Work"` with physical
`"repro_work"`, dlq `"repro_work_dlq"`, table `"pgmq.q_repro_work"`: it FAILS today
with a false `WqPhysicalDivergence` and must validate cleanly after (asserted
`errorCodesOf … shouldBe []`). PASSING fixture `workqueue-hashed-logical.keiro` — the
over-43-character logical above with the hash-derived trio, proving the fallback path.
`test/fixtures/dispatch-dedup-ghost-queue.keiro` / `dispatch-dedup-bad-field.keiro` —
the `reservation-work.keiro` dispatch block with `seenIn queue = ghost_queue` /
`seenIn queue = reservation_work field = wrong_field`; expect
`DispatchDedupQueueUnresolved` / `DispatchDedupFieldUnresolved`.

Result and proof: every fixture above produces its listed code(s); the updated
canonical fixtures (`reservation-work.keiro`, `intake.keiro`, `emit.keiro`,
`reservation.keiro`, `subscription.keiro`, `surge-service.keiro`) and all skeletons
still validate clean; the scaffold pin test is byte-stable; the extended
`keiro-dsl-conformance-queue-runtime` suite proves derivation parity with the live
`queueRef`.

### Milestone 6 — Documentation true-up, code registry, and full verification

Goal: the notation documentation stops claiming checks that do not exist (or now exist
differently), and the whole toolchain is proven green.

Work: in `agents/skills/keiro-dsl-authoring/NOTATION.md`, make exactly these minimal
edits: (1) line 145's comment `# captured fixture; validator re-derives + checks drift`
is now TRUE for all three names — reword to make the trio-wide check explicit
(`# captured fixture trio; validator re-derives physical/dlq/table and checks drift`);
(2) line 180's `# child id MUST differ from parent's` claim is removed per the B1
decision — replace the comment with `# child id derived by the via-function hole (see
generated hole docs)`; (3) since the example block at line 177 (`sleep cooling-off
after coolingOffDelay`) would now fail the new sleep-delay resolution rule as written,
add `coolingOffDelay` to the example workflow's `in … { … }` field list so the skill's
own example checks clean. No other NOTATION.md content changes (plan 110 owns the
holistic refresh, including re-auditing every "Checked:" list against the delivered
validator).

Then run the full verification battery (Concrete Steps below): unit suite, every
conformance suite, `check` against every fixture and every skeleton, and a manual
before/after transcript for at least one repro per audit finding. Update Progress,
Surprises & Discoveries, and Outcomes & Retrospective.


## Concrete Steps

All commands run from the package directory `/Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl`
unless stated otherwise (the unit suite reads fixture paths relative to it).

Build and unit-test loop, after every milestone:

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro/keiro-dsl
cabal build lib:keiro-dsl
cabal test keiro-dsl-test
```

Expected tail of a green unit run (the example count grows as fixtures are added):

```text
Finished in ... seconds
<N> examples, 0 failures
Test suite keiro-dsl-test: PASS
```

Demonstrating a rule end-to-end with the CLI (example: duplicate workflow labels).
BEFORE the milestone lands, the failing fixture exits 0:

```bash
cabal run keiro-dsl -- check test/fixtures/workflow-dup-label.keiro; echo "exit=$?"
```

```text
exit=0
```

AFTER, it exits non-zero with a row-anchored diagnostic on stderr:

```text
test/fixtures/workflow-dup-label.keiro:10: error[WorkflowDuplicateLabel]: workflow 'Dupes' declares label 'do-work' more than once; labels key deterministic replay, so a duplicate label replays the first occurrence's journaled result
exit=1
```

(The message wording may be refined during implementation; the code, the line anchoring
on the second occurrence's row, and the non-zero exit are the contract.)

Wiring a rule into the test suite follows the existing convention exactly — one
`it`-block per fixture inside the relevant `describe` in `test/Main.hs`, e.g.:

```haskell
it "rejects a duplicate workflow body label as WorkflowDuplicateLabel" $ do
    codes <- errorCodesOf "test/fixtures/workflow-dup-label.keiro"
    codes `shouldContain` [WorkflowDuplicateLabel]
```

and for passing counterparts / false-positive removals:

```haskell
it "accepts an upper-cased logical queue name (derivation matches live queueRef)" $ do
    codes <- errorCodesOf "test/fixtures/workqueue-uppercase-logical.keiro"
    codes `shouldBe` []
```

Skeleton regression (already pinned; must stay green after the M4 skeleton edits):

```bash
cabal run keiro-dsl -- new process | cabal run keiro-dsl -- check /dev/stdin; echo "exit=$?"
```

```text
exit=0
```

Conformance suites, per milestone touch-point and all together at M6 (from the repo
root, since these are separate cabal test-suites of the keiro-dsl package):

```bash
cd /Users/shinzui/Keikaku/bokuno/keiro
cabal test keiro-dsl-conformance keiro-dsl-conformance-queue-runtime keiro-dsl-conformance-workflow
cabal test keiro-dsl    # M6: the full battery — the unit suite plus all 17 conformance suites green
```

The M5 anti-drift cross-check lives in
`keiro-dsl/test/conformance-queue-runtime/Main.hs`; its build-depends stanza in
`keiro-dsl/keiro-dsl.cabal` (currently `base`, `keiro-pgmq`, `text`) gains `keiro-dsl`
and `pgmq-core`. Its output must include a line per vector, e.g.:

```text
derivedQueueTrio "Repro.Work" == live queueRef: True
derivedQueueTrio "hospital_capacity.reservation_work.per_hospital_fifo_lane_assignments" == live queueRef: True
```

Commit after each milestone with a conventional message, e.g.
`feat(dsl-validate): add workflow, rule, and operation validation (EP-104 M3)`.


## Validation and Acceptance

Acceptance is behavioral, per finding. For every row below, "before" means the current
working tree (the fixture exits 0 from `keiro-dsl check`), and "after" means the listed
diagnostic code(s) appear with Error severity and the exit code is non-zero. All
fixtures are committed under `keiro-dsl/test/fixtures/` and asserted in
`keiro-dsl/test/Main.hs` via `errorCodesOf`/`diagnosticCodesOf`.

- B1: `workflow-dup-label.keiro` → `WorkflowDuplicateLabel`;
  `workflow-unresolved-fields.keiro` → `WorkflowIdFieldUnresolved`,
  `WorkflowSleepDelayUnresolved`. Passing: updated `workflow.keiro`, workflow skeleton.
- B2: `rule-not-total.keiro` → `RuleNotTotal`, `RuleCaseUnknownCtor`, `ClockSampled`;
  `rule-bad-domain.keiro` → `RuleDomainUnresolved`. Passing: `reservation.keiro`
  (its `lifeCriticalOverride` rule is total over `PatientAcuity` with pure boolean bodies).
- B3: `process-ghost-refs.keiro` → `ProcessUnresolvedRef` (×5: advance command,
  dispatch command, fire command, projection, schedule) and
  `ProcessDispatchIdSupplied` (advance arm); `process-bad-timer.keiro` →
  `ProcessTimerCeilingInvalid` and `ProcessFieldBindingUnresolved`. Passing: updated
  `hospital-surge.keiro`, `surge-service.keiro` (positive projections case), process skeleton.
- B4: `operation-ghost-aggregate.keiro` → `OperationUnresolvedRef`;
  `operation-signal-value.keiro` → `AwaitSignalValueMismatch`. QueryOp: the updated
  `workflow.keiro`'s `query transferDecision` still passes (deferral stub), and the
  stub's Haddock names plan 107 as its completion.
- B5: `workqueue-incomplete.keiro` → `WqDispositionIncomplete`;
  `workqueue-dup-row.keiro` and `intake-dup-row.keiro` → `DispositionDuplicateOutcome`.
  Passing: `reservation-work.keiro`, `intake.keiro`, both skeletons.
- B6: `intake-topic-mismatch.keiro` and `emit-topic-mismatch.keiro` →
  `TopicAffinityMismatch`. Passing: `intake.keiro`, `emit.keiro` (affinity already holds).
- B7: `statusmap-dangling.keiro` → `StatusMapDanglingKey` (×2) + `StatusMapNotTotal`;
  `statusmap-dup-key.keiro` → `StatusMapDuplicateKey`. Passing: all updated full-name
  status-maps; scaffold pin test byte-stable (proves zero generated-code churn).
- B8: `aggregate-bad-refs.keiro` → `WriteTargetNotRegister`, `UndeclaredCommand`,
  `RegisterInitialOutOfScope`. Passing: `reservation.keiro`, aggregate skeleton.
- B9: `duplicate-names.keiro` → `DuplicateNodeName`, `DuplicateEnumCtor`,
  `DuplicateEnumWire`, `DuplicateIdPrefix`, `DuplicateCommandName`,
  `DuplicateEventName`. Passing: every existing fixture (all names unique).
- B10: `workqueue-dlq-divergent.keiro` → `WqDlqDivergence`;
  `workqueue-table-divergent.keiro` → `WqTableDivergence`;
  `workqueue-uppercase-logical.keiro` flips from a FALSE `WqPhysicalDivergence` today
  to clean; `workqueue-hashed-logical.keiro` passes with the hash-fallback trio; the
  conformance-queue-runtime cross-check equates `derivedQueueTrio` with live `queueRef`
  over the vector list.
- B11: `dispatch-dedup-ghost-queue.keiro` → `DispatchDedupQueueUnresolved`;
  `dispatch-dedup-bad-field.keiro` → `DispatchDedupFieldUnresolved`. Passing:
  `reservation-work.keiro` (its `seenIn queue` arm resolves to its own workqueue and
  the `reservation_id` wire name).
- B12: a unit test asserts exactly ONE `ProcessFireAtNotInjected` for a fully-unknown
  `fireAt` field (two today), and row-anchored line numbers for `UnreachableState` and
  duplicate-disposition diagnostics (assert on `line` of the `Diagnostic`, which the
  existing helpers expose).
- Docs: `agents/skills/keiro-dsl-authoring/NOTATION.md` no longer claims the child-id
  check, describes the trio check accurately, and its workflow example's sleep field is
  declared. Verified by reading the diff — no test hooks documentation.

Global regression acceptance: from `keiro-dsl/`, `cabal test keiro-dsl-test` green;
from the repo root, all keiro-dsl conformance suites green; `keiro-dsl check` exits 0
for every skeleton (`new <kind> | check /dev/stdin`) and for every canonical fixture;
the round-trip property is green (locations are `Eq`-ignored, so this pins that the
`Loc` additions did not disturb printing).


## Idempotence and Recovery

Every step is additive code plus fixture edits in one package; re-running any build or
test command is safe and side-effect-free (the unit suite only reads fixtures; no
scaffold-to-disk step is part of this plan's tests). Each milestone compiles and passes
the full unit suite independently, so work can stop and resume at any milestone
boundary; if a milestone must be abandoned mid-way, `git checkout -- keiro-dsl` restores
the tree (no generated artifacts or databases are involved). The riskiest structural
edit — M1's `Loc` additions — is guarded by the compiler (every constructor site is a
type error until updated) and by the round-trip property; if an unexpected consumer
turns up outside keiro-dsl, that is a scope violation by definition (only keiro-dsl
consumes its own Grammar), so stop and re-check rather than editing runtime packages.
Fixture renames/edits are covered by the suite itself: any assertion that goes red
after a fixture edit is the recovery signal. Commit at every milestone boundary so
`git revert` of a single milestone is always possible.


## Interfaces and Dependencies

New `DiagnosticCode` constructors — the single authoritative registry for this plan,
appended as one block at the end of the existing enum in
`keiro-dsl/src/Keiro/Dsl/Validate.hs` (plans 107/108/109 append their node-specific
codes AFTER this block and must not rename these 27):

```haskell
    | -- EP-104 (validator soundness).
      WorkflowDuplicateLabel
    | WorkflowSleepDelayUnresolved
    | WorkflowIdFieldUnresolved
    | RuleDomainUnresolved
    | RuleNotTotal
    | RuleCaseUnknownCtor
    | ProcessFieldBindingUnresolved
    | ProcessTimerCeilingInvalid
    | OperationUnresolvedRef
    | AwaitSignalValueMismatch
    | WqDispositionIncomplete
    | DispositionDuplicateOutcome
    | TopicAffinityMismatch
    | StatusMapDanglingKey
    | StatusMapDuplicateKey
    | WriteTargetNotRegister
    | RegisterInitialOutOfScope
    | DuplicateNodeName
    | DuplicateEnumCtor
    | DuplicateEnumWire
    | DuplicateIdPrefix
    | DuplicateCommandName
    | DuplicateEventName
    | WqDlqDivergence
    | WqTableDivergence
    | DispatchDedupQueueUnresolved
    | DispatchDedupFieldUnresolved
```

Reused existing codes (no renames, wider populations): `ClockSampled` and
`GuardAtomOutOfScope` (rule bodies), `UndeclaredCommand` (`fields(Cmd)` event bodies),
`ProcessUnresolvedRef` (command/schedule/projection resolution),
`ProcessDispatchIdSupplied` (advance arm), `StatusMapNotTotal` (exact matching),
`WqPhysicalDivergence` (faithful derivation).

New exported helpers from `Keiro.Dsl.Validate` at end of M5:

```haskell
-- | The validator's re-derivation of the live Keiro.PGMQ.Runtime.queueRef trio:
-- (physical, dlq, table). Kept algorithm-identical to keiro-pgmq; parity is pinned
-- by the keiro-dsl-conformance-queue-runtime cross-check.
derivedQueueTrio :: Text -> (Text, Text, Text)
```

Internal (not exported) deferral stub, defined once and called from the QueryOp arm of
`validateOperation` and the read-model arms of `validatePgmqDispatch`:

```haskell
-- | Read-model reference resolution is DEFERRED: the grammar has no readmodel node
-- to resolve against (2026-07 audit, finding E1). Returns no diagnostics today.
-- docs/plans/107-add-a-first-class-read-model-node-with-registration-schema-and-consistency-to-keiro-dsl.md
-- replaces this body with real resolution once the node exists.
resolveReadModelRef :: Spec -> Loc -> Text -> Name -> [Diagnostic]
resolveReadModelRef _spec _loc _context _name = []
```

Grammar interface changes (M1): `StateDecl` gains `stLoc :: !Loc`; `DispositionRow`
gains `drLoc :: !Loc`; `WqDispRow` gains `wqdLoc :: !Loc`; `DispatchNode` gains
`dispLoc :: !Loc`; `EmitMapRow` gains `emrLoc :: !Loc`; `WfBodyItem` constructors each
gain a trailing `!Loc`. No other Grammar types change; `Loc`'s value-ignoring `Eq`
(`Grammar.hs:119-123`) is the invariant that keeps the round-trip property intact.

Package/test dependencies: the keiro-dsl LIBRARY dependency set is unchanged (base,
containers, megaparsec, parser-combinators, prettyprinter, text). The
`keiro-dsl-conformance-queue-runtime` test-suite stanza in `keiro-dsl/keiro-dsl.cabal`
adds `keiro-dsl` and `pgmq-core` (both already built in this workspace; `keiro-pgmq`
is already a dependency of that suite) for the M5 derivation cross-check, using
`Keiro.PGMQ.Runtime (queueRef, QueueRef (..))` and `Pgmq.Types (queueNameToText)`.

Cross-plan integration statements (restating the load-bearing ones in one place):
plan 106 must land the SAME status-map semantics in the scaffold lowering — exact match
on the full event name, duplicate keys and dangling keys rejected — and whichever of
104/106 lands second verifies against the other's fixtures; plan 107 completes
`resolveReadModelRef` and extends `procProjections`/CommandOp-projection resolution to
readmodel nodes; plan 105 owns identifier hygiene and the `mapPartial` syntax this
plan's totality rule continues to read; plans 107/108/109 append `DiagnosticCode`
constructors after this plan's block without renaming; plan 110 owns the holistic
NOTATION/skill refresh beyond M6's two claim corrections.
