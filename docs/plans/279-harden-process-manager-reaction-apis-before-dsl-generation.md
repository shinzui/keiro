---
id: 279
slug: harden-process-manager-reaction-apis-before-dsl-generation
title: "Harden process-manager reaction APIs before DSL generation"
kind: exec-plan
created_at: 2026-09-10T04:33:45Z
intention: "intention_01m24setxxeyz93jyt4fjf00gy"
provenance:
  created_by:
    model: "gpt-6"
    harness: "codex"
    at: 2026-09-10T04:33:45Z
  revisions:
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-10T12:42:20Z
      mode: "update"
      note: "Restored creation provenance for the plan authored in this session using its original created_at timestamp; model identifier corrected to gpt-6 from the session instructions."
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-12T13:01:16Z
      mode: "update"
      note: "Clarified recovery and ordering contracts, bounded witness scans, specified strict dispatch accounting, and expanded concurrency/performance acceptance."
  reviews:
    - model: "gpt-6"
      harness: "codex"
      at: 2026-09-12T13:01:16Z
      verdict: "changes-requested"
      note: "Source review found target-race reconciliation gaps, silent timer race limits, and missing scan/allocation bounds; applied corrections in update mode, runtime feasibility remains unproven."
---

# Harden process-manager reaction APIs before DSL generation


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Promote established architectural decisions into
`docs/adr/` during implementation.


## Purpose / Big Picture


A Haskell application should be able to react to an event by optionally advancing its own
process state, dispatching commands, and scheduling or cancelling timers through one small
runtime API. The application should receive honest results for accepted, silent, duplicate,
and deliberately non-advancing reactions, and should recover missing target dispatches after
a crash by recognizing accepted saga receipts and skipping their timer phase. Unconditional
timers on silent/non-advancing executions remain repeatable, including in races with acceptance.

This plan hardens that runtime composition before
[plan 273](273-make-process-manager-reactions-first-class-in-keiro-dsl.md) generates calls to
it. The proof is a handwritten public-API example and PostgreSQL tests, requiring no DSL parser,
checker, generated module, or language registration. Existing process-manager and router
entry points keep their signatures, deterministic identities, and behavior. The additive
reaction module composes the existing command, projection, timer, and worker machinery.

This is not a general workflow redesign. It adds no effectful recipient selection, arbitrary
saga-state callback, cross-stream transaction, new timer generation model, or durable receipt
for silent decisions. Silent rejection/no-op may be evaluated again on redelivery, as in the
existing domain command API. If implementation reveals a need for such receipts, revise this
plan explicitly rather than hiding new persistence behind a DSL convenience.


## Progress


- [x] (2026-09-12) Review API design, recovery, performance, and maintainability against command, process-manager, timer, store, and ADR contracts; incorporate the corrections below. This is plan validation, not runtime acceptance.
- [ ] M0: prove accepted-event witness recovery, optimistic retry, same-source races, and silent redelivery with the existing command API; record the feasibility verdict.
- [ ] M1: add transactional cancellation and the frozen target-keyed reaction identity with PostgreSQL and literal-vector tests.
- [ ] M2: implement the additive reaction model and once runner, including explicit outcomes, timer accounting, witness recovery, and partial dispatch tests.
- [ ] M3: add worker integration and a handwritten public-API example; prove acknowledgement, failure, and scaling behavior.
- [ ] M4: document the runtime contract, distill its ADR, run compatibility gates, and hand the completed API to plan 273.


## Surprises & Discoveries


The 2026-09-12 source review found that `dispatchDeduplicatedCommand` reconciles only
`DuplicateEvent` failures through `confirmBenignDuplicate`. A concurrent target winner can
instead leave the loser with `CommandRejected` or a successful zero-event result after optimistic
retry. Reusing that helper alone does not establish the new runner's duplicate-result contract.
M2 must add reaction-local reconciliation and explicit target-race tests.

A silent command's final existence probe and its unconditional timer transaction are separate.
Another delivery may accept between them; the silent delivery can then mutate timers after the
accepted transaction. Neither `Once` nor a second unprotected probe serializes all timer effects.
The plan now limits the no-repeat guarantee to executions that establish accepted status and
recommends accepted-only effects for timers that require that guarantee.

Witness paging bounds event count per page, not total recovery work or bytes per event. The
public store API has no read-by-id operation. Capture a finite stream-version ceiling so missing
witness recovery terminates even during continuous appends; measure history depth as well as fan-out.

A strict record containing a list is not sufficient to release its elements or an enclosing
accepted saga outcome. The worker must reduce the saga outcome before target dispatch and force
its summary counters and failure-list spine as it progresses. Caller-supplied follow-ups and
failure records still require memory proportional to their sizes.


## Decision Log


- Decision: Extract runtime feasibility and implementation from plan 273 into this prerequisite.
  Rationale: The runtime must have an independently useful and tested contract before the DSL
  depends on it. Plan 273 retains parsing, checking, generation, fingerprints, diff, and generated
  conformance; it does not own a second runtime implementation.
  Date: 2026-09-10
- Decision: Add `Keiro.ProcessManager.Reaction` beside the historical API. Import shared public
  helpers from `Keiro.ProcessManager`, without making the parent import or re-export the child.
  Rationale: This avoids an import cycle and preserves old callers without a broad refactor.
  Date: 2026-09-10
- Decision: Accepted follow-ups are a fixed list computed from input. An existing first saga
  event proves acceptance; it is not an API for reconstructing an arbitrary accepted batch.
  Rationale: Only the first event receives the deterministic manager id. Neither the new runtime
  nor the intended DSL needs event-value-dependent follow-ups.
  Date: 2026-09-10
- Decision: Use a sum for no-advance versus advancing reactions so accepted-only effects cannot
  be attached to an absent command. Preserve typed saga outcomes and distinguish duplicates.
  Rationale: Invalid combinations should not become generator conventions or silent runtime defaults.
  Date: 2026-09-10
- Decision: Retain non-durable silent decisions and separate target transactions. Timer effects
  commit before target dispatches; they do not imply atomic fan-out or cancellation of an
  already-running timer callback.
  Rationale: These are the existing command/store boundaries. Document and test them explicitly.
  Date: 2026-09-10
- Decision: Keep targets on the existing validated-stream command path in this first API; typed
  saga outcomes are needed for acceptance gating, while an additional typed-target reaction
  family is not required by the current DSL scope.
  Rationale: Avoid multiplying API families before a concrete caller requires them. Existing
  `DomainProcessManager` remains available and unchanged.
  Date: 2026-09-10


- Decision: Preserve non-durable silent behavior and state its concurrency limit explicitly.
  Rationale: An existence probe cannot serialize an eventless decision with a concurrent accepted
  transaction. Accepted-only timers are the supported choice for acceptance-bound effects;
  serializing silent effects would require a separate locking or receipt design.
  Date: 2026-09-12
- Decision: Keep witness decoding as an explicit integrity check, with a captured finite read
  ceiling, and add reaction-local target reconciliation without changing historical helpers.
  Rationale: This preserves the proposed integrity contract while bounding missing-witness
  termination and avoids changing legacy runner behavior through a shared helper.
  Date: 2026-09-12
- Decision: Use strict physical-target occurrence counters and reduce saga results before worker
  dispatch; retain detailed results only for the once runner.
  Rationale: Prevent quadratic prefix scans and accidental retention of accepted payloads without
  introducing another public configuration family.
  Date: 2026-09-12


## Outcomes & Retrospective


The 2026-09-12 review retains the additive public model and five implementation milestones,
with required corrections to concurrency recovery, finite witness scanning, replay preconditions,
and worker allocation. The existing author and revision provenance identify `gpt-6` / `codex`;
there were no recorded review entries before this pass. Runtime correctness remains subject to
M0 and the new PostgreSQL acceptance cases; no implementation milestone is complete. The baseline
process-manager command was attempted during review but stopped at dependency solving, before any
test ran: the available Cabal index offered `pgmq-effectful-0.5.0.0`, while workspace package
`jitsurei` requires `>=0.6 && <0.7`. This is environment evidence, not a new dependency constraint
or a reason to weaken existing bounds. Refresh/verify the package index and authoritative releases
before retrying; if still unresolved, record the blocker rather than claiming runtime acceptance.


## Context and Orientation


Run commands from the repository root, which contains `cabal.project` and `Justfile`.
`keiro/keiro.cabal` defines the runtime library and `keiro-test`. Tests use an ephemeral
PostgreSQL fixture, initialized through `Keiro.Test.Postgres` in the `keiro-test-support`
package. The existing `keiro/test/Main.hs` holds `withFreshResourceStore`, `counterProcessManager`,
`timerOnlyProcessManager`, and the Counter model, including deterministic race tests using
`RunCommandOptions.beforeAppend`. The prior validation of plan 273 ran 25 process-manager tests,
10 DSL process/timer tests, and the 39-entry corpus policy successfully. These are baseline
observations, not evidence for the new API.

A process manager, or saga, owns a private event stream recording its coordination state.
The input's correlation id chooses the saga instance through `streamFor`. A reaction is a pure
function from a decoded input to an optional saga command and a finite set of follow-ups.
A target is a separate aggregate stream receiving a dispatched command. A durable timer is a
row in `keiro.keiro_timers` claimed by a worker. A witness is the already-recorded saga event
whose id proves an accepted append happened. Optimistic retry means rehydrating the saga and
selecting its command transition again when another writer changes its stream version before
append. It is not permission to execute follow-ups from a discarded attempt.

For each source event id, callers must keep decoding, correlation, `streamFor`, reaction branch,
command payloads, timer ids, and supplied timestamps stable across retries. A pure function alone
cannot guarantee this if its input is enriched from changing data or its configuration changes.
Derive deadlines from recorded input time, not delivery wall-clock time. Saga streams must remain
private to the manager and retain their acceptance witnesses for the supported replay lifetime.
Truncation, deletion, foreign links, or identity reuse invalidate that precondition; codec decoding
is a compatibility check, not proof that an arbitrary linked event came from this reaction.

`keiro/src/Keiro/ProcessManager.hs` defines `ProcessManagerAction` with a mandatory command,
commands, and timers. `runProcessManagerOnce` probes the deterministic manager id, schedules
timers through an append callback, and dispatches targets separately. Duplicate manager delivery
still attempts targets, allowing recovery after partial success. An eventless manager command
schedules timers in a separate transaction. `DomainProcessManager` adds typed outcomes for targets,
not for the saga. Exported `firstExistingEventId`, `confirmBenignDuplicate`,
`dispatchDeduplicatedCommand`, `decideForFailures`, and acknowledgement helpers provide reusable
building blocks. The `ProcessManagerAction` Haddock incorrectly says all three parts are atomic;
correct that comment when documenting the new contract, without changing the legacy behavior.

`keiro/src/Keiro/Command.hs` already supplies `DomainCommandHandler`, `DomainCommandOutcome`,
and `runDomainCommandWithSqlEvents`. Its callback takes `[(co, RecordedEvent)]` and `AppendResult`
inside the append transaction and runs only for an accepted non-empty event batch. The command
path hydrates once per attempt and retries optimistic conflicts. `assignEventIds [managerId]`
sets only the first event's id; remaining events receive ordinary ids. A silent decision writes
no event and has no stable receipt. `beforeAppend` is an observation/test hook outside the append
transaction, not an effect-commit callback.

`keiro/src/Keiro/Timer/Schema.hs` exposes `scheduleTimerTx` and `scheduleTimerOnceTx`.
The former returns unit and only updates an existing row while it is Scheduled; the latter
returns whether it inserted a new row. The private `cancelTimerStmt` changes Scheduled or
Firing rows only when `resume_claim_token IS NULL`. `cancelTimer` currently starts its own
transaction. `keiro/src/Keiro/Timer.hs` is the public facade. Fired, cancelled, and foreground
claimed rows must not be resurrected by reaction scheduling.

`keiro/src/Keiro/Router.hs` provides the identity-encoding precedent: UUIDv5 with the URL
namespace over ordered fields encoded as decimal UTF-8 byte length, a colon, and the UTF-8 bytes.
Reaction dispatch keeps declared order rather than router target sorting, and therefore counts
earlier commands to the same physical target stream. Reordering different targets preserves
individual identities. Swapping two commands to the same target or changing command payloads
can reuse an identity for a different action. Deploying changed reactions therefore requires
an explicit drain boundary; changing a version annotation cannot fix this.

Dependency discovery for the preceding review used Mori to locate
`mori://shinzui/kiroku/packages/kiroku-store`. Its `Kiroku.Store.Read` exports point existence
checks and paged stream reads, but not a read-by-event-id API. Witness recovery can page the
saga stream with bounded memory. Do not query private store tables or require a dependency
upgrade for this plan. If the implementation needs an unfamiliar dependency API, locate it with
`mori registry search`, `mori registry show --full`, and `mori registry docs` and read its source.
Verify registry releases and upstream tags before any new dependency bound or workaround.

[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
freezes existing ids and requires UTF-8 bytes and frozen vectors for new derivations.
[ADR-29](../adr/0029-typed-domain-decisions-are-successful-additive-command-outcomes.md)
makes the selected saga transition the decision authority, keeps silent outcomes non-durable,
and distinguishes duplicate witnesses from original event batches. It also requires workers to
reduce handled outcomes rather than retain payloads for the full fan-out.
[ADR-25](../adr/0025-worker-loops-isolate-failures-per-pass-and-per-item-and-report-partial-progress.md)
requires failure isolation, cancellation propagation, and honest completion counts.
[ADR-30](../adr/0030-declarative-router-selection-is-bounded-target-normalized-and-coordination-versioned.md)
provides target-keyed identity and partial-success precedents without requiring reactions to
adopt effectful router selection or sorting.
[ADR-39](../adr/0039-foreground-timer-resume-uses-expiring-token-ownership.md)
requires all ordinary ID-only timer mutations to exclude token-bearing foreground claims.

[Plan 274](274-expose-process-manager-inspection-reads.md) separately owns inspection reads and
reaction provenance metadata. This plan does not implement inspection or duplicate its metadata
schema. Preserve caller metadata and accommodate that plan's append integration if it lands
first. New runtime writes must not bypass established provenance merely because they use a
new runner. No master plan is needed for this two-plan prerequisite relationship.


## Plan of Work


### M0: prove the composition before fixing the public API


Add a `describe "process reaction API feasibility"` block in `keiro/test/Main.hs` using the
existing database fixture and Counter-style typed transducers. Keep test-only synchronization
helpers local. First invoke `runDomainCommandWithSqlEvents` with one supplied deterministic
manager id and a command emitting two events. Assert the callback sees both events, that the
first has the supplied id, and that paging the persisted stream locates and decodes that first
event without pretending to recover the original batch boundary.

Next force an optimistic conflict with a one-shot `beforeAppend` hook: another command changes
the saga so the retried command chooses a different transition or becomes silent. Assert that
the callback runs only for the successfully committed accepted attempt. Synchronize two deliveries
of the same source id with an `MVar` barrier and establish the failure/silent-return shapes the
coordinator must reconcile. Ensure the hook does not wait a second time on retry. Add a separate
silent delivery, unrelated saga progress, and redelivery example showing that the same source can
later accept; the first silent attempt has no durable decision. Also pause a silent delivery after its final
negative probe, allow unrelated progress and a same-source accepted delivery to commit, then
release the silent delivery's unconditional timer transaction. Assert the documented repeatable
effect, not an impossible once-only guarantee. Use test-local effect interception for this barrier.

Run the M0 command below and record actual observed outcomes. Promote these tests into permanent
regression coverage. The gate passes when the existing command path provides all these semantics
without a parallel saga-state evaluator or new receipt schema. If it does not, record the concrete
failing case and revise this plan before proceeding; do not start DSL work to work around it.


### M1: add the missing timer primitive and freeze reaction identities


Add `cancelTimerTx :: TimerId -> Tx.Transaction Bool` inside
`keiro/src/Keiro/Timer/Schema.hs`, export it through `keiro/src/Keiro/Timer.hs`, and implement
`cancelTimer` by running the wrapper in its existing transaction. Reuse the exact existing SQL,
including the resume-token exclusion. No migration is required. In the feasibility block, cancel
a scheduled timer inside an accepted saga callback and verify a subsequent claim finds nothing.
Use a condemned transaction to prove rollback restores both timer and saga state. Cover expired
and unexpired foreground claims, fired and cancelled rows, absent-row cancellation, and re-arming:
cancel of an absent id returns False and creates no tombstone, so a later schedule may insert it.

Create the separately exposed `keiro/src/Keiro/ProcessManager/Reaction.hs` module and register it
in `keiro/keiro.cabal`. Initially it can expose just `deterministicReactionCommandId`. Its seed
fields, in exact order, are `keiro`, `process-reaction`, manager name, correlation id, canonical
source UUID text, physical target stream text, and decimal zero-based same-target occurrence.
Encode each as decimal UTF-8 byte length followed by `:` and its bytes, concatenate, and hash
with UUIDv5's URL namespace. Do not add reaction version, fingerprints, payloads, or a positional
legacy fallback to this new dispatch family. Saga ids still use `deterministicCommandIdProbes`
with index minus one, including its existing compatibility probes.

Add ASCII, Unicode, embedded-colon, target-separation, occurrence, and router-family-separation
vectors under the existing `Keiro deterministic id derivation` group. Compute the new UUID literals
once during this milestone, cross-check the explicit byte preimage, and freeze them. Never update
existing identity literals. The M1 tests must prove the exact seed encoding and unchanged legacy ids.


### M2: implement the reaction once runner and recovery


Extend the new module with the types in Interfaces and Dependencies. `react` remains pure and
receives only decoded input. The no-advance constructor cannot carry accepted-only effects.
For an advancing constructor, unconditional follow-ups are followed by accepted-only follow-ups
when acceptance is established. Within that combined list, timer operations retain their relative
order and target commands retain theirs, but timer SQL commits before any target dispatch.
This is two execution phases, not arbitrary cross-stream source ordering.

For an advance, derive the current saga id and legacy probes using index minus one. A matching
id in the intended saga stream enters duplicate recovery: page forward using a positive bounded
page size until the exact matched event is found, decode only that event with the saga codec,
and enable the fixed accepted list. After the positive probe, capture `getStream`'s `version`
as the finite ceiling. Start `readStreamForward` at `StreamVersion 0`; its cursor is exclusive,
so advance to the last returned `streamVersion`, not that version plus one. Use an internal
page size of 256, with a private smaller-size seam for tests. Stop on an empty page or when the
captured ceiling has been reached, ignoring later appends. A vanished stream or reaching the
ceiling without the matched event is `ReactionWitnessMissing`. Memory holds at most one page
of event payloads, whose individual byte sizes are not capped. A witness at position H costs
O(H) transferred events and O(ceil(H / pageSize)) page reads plus bounded probe/metadata reads; this deliberate integrity check is
more expensive than legacy existence-only duplicate recovery. Missing or undecodable witnesses
fail explicitly without dispatch or acknowledgement. Do not hydrate or run the saga command on
this path, reconstruct a fictitious original batch, or re-run timer SQL that committed with the
witness.

On a probe miss, invoke `runDomainCommandWithSqlEvents` with `[managerId]`. In its callback,
execute the timer subsequence for the combined unconditional and accepted lists and return its
committed-effect summary. For an accepted outcome, return the original typed batch and command
result to the one-shot caller. For a silent outcome, re-probe first: a concurrent winner may have
committed the same source while the optimistic loser now sees a silent edge. Recover a winner's
witness if present; otherwise return the typed silent decision and execute only unconditional
timer effects in a separate transaction. Reconcile append failures with the intended-stream
witness too, including post-conflict unmatched commands. A collision only in another stream or
with another id never counts as a successful duplicate. If no witness exists, surface the original
failure and execute no follow-ups. Preserve infrastructure failure and asynchronous cancellation
behavior; witness reconciliation must not mask an unrelated store failure when it cannot confirm
an accepted append.

For no-advance, skip all saga reads and commands and run unconditional timers in their own
transaction. Return `ReactionNotAdvanced`. This path and a genuinely silent path have no saga
receipt; their unconditional timer operations may repeat on redelivery. A replayed no-advance
schedule can reset a still-Scheduled deadline. `Once` means insert-only while the row exists,
including terminal rows; it is not a new timer
generation and does not make cancellation durable for an absent id. It preserves the existing
row's deadline and payload; `Rearm` replaces both only while Scheduled. Neither can revive a
Firing, Fired, Cancelled, Dead, or foreground-owned row.

The silent re-probe is best-effort reconciliation, not a lock: an accepted delivery can commit
after a negative probe and before the silent timer transaction. Unconditional timers can therefore
repeat even around a concurrent acceptance. Put timers that must belong exclusively to acceptance
in `onAccepted`; do not claim exactly-once unconditional effects or add an unplanned receipt table.
A genuinely silent result remains an honest observation of that invocation even if another delivery
accepts later.

Dispatch the selected target commands with `dispatchDeduplicatedCommand` and
`runCommandWithProjections`, assigning the new target-keyed id to the first target event. Count
same-target occurrences over the selected command list, independent of timer positions. Resolve
the physical target name once per command and use a strict `Data.Map.Strict StreamName Int` counter
in one traversal: O(N log(D + 1)) work and O(D) counter space for N commands and D distinct targets.
Do not count occurrences by repeatedly scanning earlier commands. Retain
source command order and attempt every command, reporting failures in their positions, following
the existing once-runner policy. A later failure cannot undo an earlier commit; replay deduplicates
successful eventful targets and retries missing ones. A target that emits no events has no receipt
and may be re-evaluated; the result must not invent an accepted event or duplicate id for it.
For compatibility, `PMCommandAppended` can carry a `CommandResult` with zero appended events;
its constructor name alone is not evidence of an event receipt. Document this inherited vocabulary.

Wrap the existing target helper in a private reaction dispatch function. After an unmatched command,
exhausted optimistic conflict, or zero-event success, re-probe this target's deterministic id and
return `PMCommandDuplicate` if present; otherwise preserve the original failure or zero-event result.
Keep existing duplicate-id mismatch and wrong-stream collision checks intact, propagate cancellation,
and do not convert codec/validation errors to duplicates. Add deterministic concurrent target tests
where the loser becomes unmatched and where it becomes silent. Without reconciliation, worker
rejection policy could dead-letter an already-completed target action. Keep legacy helpers unchanged.

Dispatch order is attempt order within one invocation. With attempt-every-command policy, a failed
command can commit on replay after a later command already succeeded, including on the same target.
Concurrent deliveries also do not establish a global order. Reactions must tolerate those histories;
applications requiring strict committed command order need a different policy outside this plan.

Add `describe "Keiro.ProcessManager.Reaction"` tests for each branch, with persisted row/event
assertions rather than only constructor checks. Use deterministic synchronization for distinct-source
optimistic races and same-source duplicate races. Force a timer SQL failure after an earlier timer
mutation to prove the runner's append and all its timer effects roll back. Separately induce target
failure after commit and prove saga and timers survive and replay finishes dispatch. Do not add an
application callback between these phases just to inject crashes; use store/test failure injection.
Test schedule-before-cancel and cancel-before-schedule for an existing row, no-action, timer-free
fan-out, two timers, payload persistence, and target command order including repeated targets.


### M3: prove worker use and a handwritten consumer


Add `runReactiveProcessManagerWorkerWith` and `runReactiveProcessManagerWorker` in the new module.
Use the existing `WorkerOptions`, adapter acknowledgement handle, poison/rejection policies,
`decideForFailures`, and `DispatcherProcessManager` dead-letter vocabulary. Genuine manager
command failures use emit index minus one; target failures use the zero-based overall dispatch
position, not the same-target occurrence used in identity derivation. Typed saga rejection/no-op
is a handled outcome, with only unconditional effects allowed. Witness integrity errors halt
with bounded reason codes and never expose stored payloads in telemetry or dead letters.

Share one internal execution engine between once and worker entry points, with a strict
per-dispatch accumulator for the worker so it need not construct the full detailed result list
or retain accepted saga values through all target dispatches. Parameterize the private engine's
result reduction so the worker reduces the saga outcome to a duplicate count/handled status before
entering the target loop; returning `(fullSagaOutcome, summary)` defeats this requirement. Accumulate
once-runner results and worker failures by cons and reverse once, not repeated list append. Worker
memory includes O(D) occurrence counters, O(F) failure records, and the supplied follow-up list;
it is not constant in total fan-out. Do not allocate a filtered command list and a second numbered
copy solely for worker traversal. Do not copy the new runner into
the worker, change historical APIs, or turn shared helpers into a general orchestration framework.
Keep decoding as `(msg -> Maybe (RecordedEvent, input))`, matching existing workers. Assert each
normal policy decision finalizes its source acknowledgement exactly once; cancellation or a thrown
callback/finalizer error need not finalize and must never synthesize a successful acknowledgement.
Transient errors retry, deterministic failures
follow the established policies, poison follows its policy, and asynchronous cancellation escapes.

Add `keiro/test/ReactionExample.hs` to the test component's `other-modules`. This handwritten
consumer imports only public runtime modules and exports an example manager; drive it from Main's
database fixture. Use reported/acknowledged input variants and a pure branch on severity, with
fixed injected timestamps, an accepted-only dispatch, two named timer requests with distinct ids,
and a separate timer-free/no-advance case. Target state guards make a late firing benign even if
cancellation happened after a worker had claimed the timer. Fire through the existing timer worker
and deterministic target command path: the new module does not own a new timer worker or payload
codec system.

Exercise redelivery of a fired timer and a max-attempts dead-letter case. For fan-out sizes 8, 32,
and 128, instrument the fixture's saga store reads in an uncontended first delivery and show
that increasing target count does not add saga hydration reads. Count target reads separately.
Optimistic retries may add saga attempts. Do not use `keiro_command_decision` as a hydration counter;
it is a decision attribute. Also exercise witness recovery with a page size small enough to force
multiple pages. For history depths 256, 1024, and 4096, place witnesses near the end, count
recovery reads and decoded events, and verify the documented linear read cost and one witness
decode. Delete or hide a probed witness before scanning while adding newer events; recovery must
stop at the captured ceiling. Measure first delivery and duplicate recovery separately. Include
all-distinct and all-same-target fan-out to exercise occurrence counting, and inspect an allocation
or heap profile with large accepted saga payloads to show the worker releases them before target
fan-out while the once result intentionally retains them. Record read counts, allocations, and
bounds without imposing a machine-specific latency gate.
The M3 acceptance is a working example with tests and no dependency on `keiro-dsl`.


### M4: document, validate compatibility, and hand off to the DSL


Update `docs/user/api-reference.md`, `docs/guides/process-managers-and-timers.md`,
`docs/user/deploy-ordering.md`, `keiro/CHANGELOG.md`, and the new module's Haddock. Include the
once/worker example, the state/result distinctions, the two transaction phases, silent and
no-advance replay, timer cancellation limits, and declared attempt order, including retry-induced
commit reordering and stable-input requirements. Correct the misleading
legacy action comment identified above. Runtime documentation belongs here; DSL notation and
its diagnostics belong to plan 273.

Explain adoption explicitly. Existing applications do not automatically switch runners. Before
switching a manager name to the new dispatch family, drain source deliveries, partial fan-out,
pending timers, and all permitted historical replays across the cutover. Otherwise retained saga
ids can recognize old acceptance while new dispatch ids append a second target action. The same
review is required for same-target command reordering or payload changes within the new family.
There is no version-number escape hatch and no automatic dual dispatch-identity fallback.

Inspect `mori show --full` and the local ADR profile before writing an ADR, allocate a fresh handle
with `okf id next`, and record the accepted runtime boundaries. Do not reuse ADR-40, which belongs
to inspection surfaces. Follow the existing profile and add log entries when timestamps advance.
Update existing ADRs only where their durable contract needs clarification. Record documentation
changes with `okf log add` in the corresponding bundles. This creates the runtime ADR that plan
273 will later extend with DSL-specific decisions instead of allocating a competing runtime ADR.

Run the full runtime suite, all generated DSL suites, corpus policy, strict affected documentation
checks, and `just verify`. Keep IR-39 proposed until plan 273 delivers its DSL acceptance. Update
plan 273's prerequisite gate with this plan's completion evidence, actual exported signatures,
identity vectors, ADR link, and any deviations. Do not start grammar changes under this plan.


## Concrete Steps


Run from `/Users/shinzui/Keikaku/bokuno/keiro` in the repository's Nix development shell. Enter it
with `nix develop` if tools are unavailable. Tests start their own disposable PostgreSQL instances.
No production store or external service is required.

Review baseline attempted on 2026-09-12:

```bash
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager"' --test-show-details=direct
```

```text
Error: [Cabal-7107]
Could not resolve dependencies:
rejecting: pgmq-effectful-0.5.0.0
conflict: jitsurei => pgmq-effectful>=0.6 && <0.7
```

`just conformance-corpus-policy` hit the same dependency-solver failure. Local Markdown link
resolution, tagged/balanced code fences, and `git diff --check` passed. No runtime tests or corpus
acceptance checks completed. Resolve package availability without weakening workspace bounds before collecting
M0 evidence. The new feasibility and Reaction test groups do not exist yet.

M0 after adding the feasibility examples:

```bash
cabal build keiro:tests
cabal test keiro:keiro-test --test-options='--match "process reaction API feasibility"' --test-show-details=direct
```

Expect a nonzero example count, zero failures, and explicit cases for a two-event acceptance,
post-conflict decision, same-source race, and silent-then-accepted redelivery. A match that runs
zero examples does not pass the gate. Record the actual transcript in this plan.

M1 and M2:

```bash
cabal test keiro:keiro-test --test-options='--match "process reaction API feasibility"' --test-show-details=direct
cabal test keiro:keiro-test --test-options='--match "Keiro deterministic id derivation"' --test-show-details=direct
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager.Reaction"' --test-show-details=direct
```

M3 and runtime compatibility:

```bash
cabal test keiro:keiro-test --test-options='--match "Keiro.ProcessManager"' --test-show-details=direct
cabal test keiro:keiro-test --test-show-details=direct
```

All named groups must run and finish with zero failures. The broader process-manager match
covers legacy and new groups; the full runtime suite exercises timer and router compatibility.

M4, including profile discovery and allocation before writing the new ADR:

```bash
mori show --full
dhall --file docs/adr/profile.dhall
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add --help
```

Use the returned handle when creating the ADR and the installed log command's argument contract
for each affected bundle. After writing documentation and updating bundle logs:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just user-documentation-validate
cabal test keiro-dsl:tests
just conformance-corpus-policy
just verify
git diff --check
```

Expect strict ADR validation to exit zero, `conformance corpus: ok`, and successful test suites.
Preserve published DSL fixture and generated bytes. Commit working milestones on the current
branch with Conventional Commits subjects and both trailers:

```text
ExecPlan: docs/plans/279-harden-process-manager-reaction-apis-before-dsl-generation.md
Intention: intention_01m24setxxeyz93jyt4fjf00gy
```


## Validation and Acceptance


Given a reported input for one saga, the handwritten example appends its accepted saga events,
commits two distinct timer rows with their supplied payloads, and dispatches the selected target
commands. Redelivery returns a duplicate saga witness, leaves timer deadlines and payloads alone,
and appends no additional event for already-eventful targets. A two-event saga command gives the
same selected accepted follow-ups on first delivery and replay without reconstructing a batch.

A forced optimistic conflict selects follow-ups from the successful decision only. Two concurrent
deliveries of the same source recover one accepted witness even if the losing command retry is
silent or unmatched. A truly silent first delivery runs no accepted effects; after unrelated saga
progress, redelivery may accept. These cases must be separate tests so a passing duplicate test
cannot conceal non-durable silent semantics. A same-source accepted delivery racing after a silent
negative probe does not fence that silent delivery's unconditional timers. The dedicated barrier
test demonstrates this limit; accepted-only timers never run on the silent branch. Concurrent target
losers that become silent or unmatched reconcile to the exact intended-target receipt and acknowledge
normally. Wrong-stream or mismatched-id collisions remain failures.

A target failure after another target succeeds leaves the first target, saga, and timers durable.
Replay completes missing dispatches. Include two commands to the same target where the first
fails and the second commits, then verify the first may commit later on replay; declared order
does not promise committed order. A failure inside timer SQL leaves neither saga nor timer
changes committed. A second distinct source with a later injected timestamp moves a Scheduled
Rearm deadline but preserves a Once deadline; replay of an accepted source changes neither.
Cancelled/Fired/foreground-owned timers remain protected. A cancellation cannot retract an
already-running callback, and the example's target guard makes that late attempt harmless.

No-action performs no saga or target append and reports NotAdvanced. Timer-only reactions skip
saga hydration and report their actual committed SQL operations. Worker tests establish exact
acknowledgement count for normal policy outcomes, bounded error rendering, and cancellation
propagation without a synthetic acknowledgement. Missing-witness tests terminate under ongoing
appends; unrelated undecodable events are not decoded. Recovery read counts grow with history,
not target count, and worker heap evidence shows accepted saga payloads are released before fan-out.
The public example compiles without DSL imports, and the 8/32/128 dispatch cases show no additional
saga hydration from fan-out alone. All historical runtime and generated DSL checks remain green.

Completion requires an accepted runtime ADR, updated documentation, and an updated prerequisite
handoff in plan 273. It does not require publishing a package or implementing Language 6.


## Idempotence and Recovery


All database tests use disposable stores and can be repeated. Keep new APIs additive and freeze
identity literals after their first reviewed derivation. A failed identity regression is fixed in
the implementation, not by updating the fixture. Scheduling and cancellation retain current schema
behavior; this plan needs no migration or destructive cleanup.

For a failure before saga commit, retry the entire input. For a failure after saga/timer commit,
recover through the recorded witness and retry target dispatches without repeating those timers.
Do not turn a missing/undecodable witness into a fresh append. Operators resolve incompatible
history or decoding before replay. A silent/no-advance path has no durable receipt; its repeatable
behavior must follow the documented scheduling mode and target idempotency limitations.

If M0 fails, retain a runnable reproducer and record what prevents the composition. Do not widen
the runtime or introduce a receipt table without revising its scope and acceptance. During rollout,
retain the old binary and do not switch identities until the documented drain is complete. Returning
to the old runner after new-family dispatches also needs a drain boundary; the shared saga witness
does not make target identity changes reversible without review.


## Interfaces and Dependencies


No dependency changes are planned. Use `Keiro.Command` for saga decisions and transactions,
`Keiro.Projection` for target append/projection transactions, `Keiro.ProcessManager` for existing
command/result and worker primitives, `Keiro.Timer` for timer effects, and the store's public
read APIs for witnesses. Existing UUID, bytestring, text, effect, and transaction dependencies
suffice. Register the new exposed module and the example's test module in `keiro/keiro.cabal`.

`FollowUp` is intentionally one small action vocabulary; its order is preserved separately in
the timer and target phases. Prefer qualified imports of Reaction for names such as `Once` and
record fields shared with other modules. Avoid adding builder classes, lenses beyond existing
repository conventions, or an effectful callback API to compensate for unspecified semantics.

The new module owns the following concrete model (shown without imports and deriving clauses):

```haskell
data ReactionPlan ci targetCi
  = NoAdvance ![FollowUp targetCi]
  | AdvanceReaction
      { command :: !ci,
        followUps :: ![FollowUp targetCi],
        onAccepted :: ![FollowUp targetCi]
      }

data FollowUp targetCi
  = FollowDispatch !(PMCommand targetCi)
  | FollowSchedule !ScheduleMode !TimerRequest
  | FollowCancel !TimerId

data ScheduleMode = Rearm | Once

data ReactionStateResult target co rejection noOp
  = ReactionNotAdvanced
  | ReactionEvaluated !(DomainCommandOutcome target co rejection noOp)
  | ReactionDuplicate !EventId

data ReactionTimerEffects = ReactionTimerEffects
  { statementsCommitted :: !Int,
    onceInserted :: !Int,
    timersCancelled :: !Int
  }

data ReactionError
  = ReactionCommandFailed !CommandError
  | ReactionWitnessMissing !StreamName !EventId
  | ReactionWitnessUndecodable !StreamName !EventId

data ReactiveProcessManagerResult managerTarget co rejection noOp commandTarget
  = ReactiveProcessManagerResult
      { managerResult :: !(ReactionStateResult managerTarget co rejection noOp),
        commandResults :: ![PMCommandResult commandTarget],
        timerEffects :: !ReactionTimerEffects
      }

deterministicReactionCommandId :: Text -> Text -> EventId -> StreamName -> Int -> EventId
cancelTimerTx :: TimerId -> Tx.Transaction Bool
```

`cancelTimerTx` lives in Timer, not in Reaction. `statementsCommitted` counts timer statements
whose transaction committed, including no-op statements; `onceInserted` and `timersCancelled`
count confirmed changes. Rearm returns no changed-row count, so the API must not invent one.
Duplicate accepted recovery reports zero fresh timer statements. Store failures continue through
the existing `Error StoreError` effect where appropriate; `ReactionError` describes command or
witness failures returned by the once runner. Raw codec errors and domain payloads are not worker
reason strings.

`ReactiveProcessManager input phi rs s ci co targetPhi targetRs targetState targetCi targetCo
rejection noOp` is a record with `name :: Text`, `correlate :: input -> Text`,
`sagaHandler :: DomainCommandHandler phi rs s ci co rejection noOp`,
`streamFor :: Text -> Stream (EventStream phi rs s ci co)`,
`targetEventStream :: ValidatedEventStream targetPhi targetRs targetState targetCi targetCo`,
`targetProjections :: Stream targetCi -> [InlineProjection targetCo]`, and
`react :: input -> ReactionPlan ci targetCi`. For an untyped saga, callers construct a handler
with `classifySilent = \_ -> SilentNoOp ()`; the existing private `silentNoOpHandler` is not a
public dependency. The public configuration contains no callback reading hydrated saga state.

`runReactiveProcessManagerOnce` takes `RunCommandOptions`, this record, `RecordedEvent`, and
input, returning `Eff es (Either ReactionError (ReactiveProcessManagerResult
(EventStream phi rs s ci co) co rejection noOp
(EventStream targetPhi targetRs targetState targetCi targetCo)))`. Use the existing once runner's
constraints: `HasCallStack`, `IOE :> es`, `Store :> es`, `Error StoreError :> es`,
`KirokuStoreResource :> es`, both saga and target `BoolAlg` constraints, and `Eq co`, `Eq targetCo`.
Do not add effectful predicate or target resolver parameters.

`runReactiveProcessManagerWorkerWith` takes the existing `WorkerOptions es msg`, command options,
manager record, `Adapter es msg`, and `(msg -> Maybe (RecordedEvent, input))`, returning `Eff es ()`
with the existing worker effect constraints. `runReactiveProcessManagerWorker` supplies default
worker options. Pin final signatures with `ReactionExample.hs` and copy the accepted signatures
into documentation and plan 273 at handoff. The parent `Keiro.ProcessManager` module does not
import or re-export the new child module.


## Revision Notes

2026-09-10: Restored creation provenance omitted by the older local initializer for the plan authored in this session, preserving the original creation timestamp, and recorded this metadata correction as a revision. Harness is recorded as codex; model is gpt-6, as identified by the session instructions. No implementation or acceptance status changed.

2026-09-10: Corrected this session's provenance model from unknown to gpt-6 at the user's request; preserved timestamps, verdicts, and authorship attribution.

2026-09-12: Validated the proposed API against the current command, process-manager, timer, and
Mori-located store sources and ADRs 24, 25, 29, 30, and 39. Added target-race reconciliation,
explicit silent/unconditional timer race limits, stable-input and retention preconditions, finite
witness scan bounds and history-cost measurements, strict occurrence counting and worker reduction,
and precise attempt-order/acknowledgement semantics. Retained the public type shape and deferred
runtime approval to the executable feasibility gate; no runtime implementation or ADR was changed.
