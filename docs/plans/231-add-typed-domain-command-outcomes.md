---
id: 231
slug: add-typed-domain-command-outcomes
title: "Add typed domain command outcomes"
kind: exec-plan
created_at: 2026-08-10T16:40:12Z
intention: "intention_01kzp88t57e0mt7cern1exb24s"
---

# Add typed domain command outcomes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Keiro applications will be able to handle one domain command and receive a typed,
exhaustive answer: an accepted decision containing the exact non-empty domain event batch,
a rejected decision containing an application-defined reason, or a successful no-op
containing an application-defined explanation. Every successful decision also carries the
ordinary `CommandResult` persistence metadata. Hydration, encoding, store, ambiguity, and
genuinely unmatched-command failures remain `CommandError`s, so application policy is not
mixed with infrastructure failure.

This is a good addition to the API because `runCommand` currently discards the typed events
after append, represents accepted epsilon transitions only as `eventsAppended = 0`, and has
only the nullary `CommandRejected` for an unmatched transition. Callers therefore have to
infer a business result from persistence metadata or duplicate domain evaluation. The new
API is additive: all existing runners and result types remain source-compatible, and an
explicit adapter offers the old collapsed behavior when desired.

The additive boundary also preserves the existing runner's cost profile: callers that keep
using `runCommand*` do not allocate domain wrappers or reason values. Outcome-aware callers
intentionally own accepted event values until they release the result, but the runtime keeps
only one typed batch and long-running coordinator workers discard handled payloads as they
advance rather than retaining an entire fan-out.

The observable demonstration is a database-backed command test. An eligible cancellation
returns `DomainAccepted` with the exact event persisted; a repeated cancellation follows an
explicit eventless transition and returns its typed rejection or no-op with zero appended
events; rejection and no-op execute no append callback, inline projection, router dispatch,
or process-manager target side effect. A forced optimistic-concurrency retry reports only
the decision from the successful final evaluation.


## Progress

- [x] (2026-08-10T17:51:10Z) Milestone 0: established legacy-command latency and
  allocation baselines before refactoring. On an Apple M1 Max (arm64), GHC
  9.12.4, and the ephemeral PostgreSQL 18.4 fixture, `accepted-1` measured
  3.12 ms ± 795 μs, `accepted-large` measured 21.0 ms ± 801 μs, and `no-op`
  measured 829 μs ± 81 μs. The combined RTS run allocated 5,495,798,472 bytes
  over the statistical suite with 37,744,304 bytes maximum residency; the
  isolated accepted-small run allocated 314,795,448 bytes over its statistical
  suite with 2,468,024 bytes maximum residency. The scratch evidence is
  `keiro/bench-command-before.csv` and remains uncommitted for the final
  same-machine comparison.
- [x] (2026-08-10T18:06:30Z) Milestone 1 functional work: added typed outcome
  values, the single-evaluation pure classifier boundary, the direct runner,
  compatibility adapter, focused tests, after-only benchmarks, and in-suite
  1.25 ratio gates. `cabal build keiro keiro:bench:keiro-bench` and the four
  focused examples pass.
- [x] (2026-08-11T14:42:12Z) Milestone 1 performance acceptance: the stable repeated large-result
  diagnostic measured the typed path at 6.29 ms ± 338 μs, 3.2 MB allocated,
  28 KB copied, and 810,656 bytes maximum residency, versus the legacy path at
  6.08 ms ± 565 μs, the same 3.2 MB allocated, 28 KB copied, and 635,312 bytes
  maximum residency. This supports one retained 100-event typed batch without
  a second encoded-workload-sized copy. Final ratio gates and baseline evidence
  passed after reboot. The final same-run guards measured accepted-small at
  1.08x, accepted-large at 1.16x, rejected at 1.02x, and no-op at 1.02x of
  their matched legacy controls. The historical legacy guard also passed:
  accepted-small remained statistically unchanged, accepted-large was 13
  percent slower, and no-op was 13 percent faster than the scratch baseline.
- [x] (2026-08-10T18:29:56Z) Milestone 2: added typed SQL and controlled-SQL
  runners, ordinary and catalog-aware projection runners, a closed decision
  telemetry dimension on spans and metrics, and deterministic retry coverage.
  The focused suite proves exact accepted callback pairs, atomic projection
  writes, accepted catalog rollback, zero silent-decision callbacks/projections,
  and final-decision freshness after conflict; all 10 focused examples pass.
- [x] (2026-08-10T18:48:07Z) Milestone 3 functional work: added additive
  domain-aware router and process-manager configurations, detailed one-shot
  results, and worker entry points. Focused tests distinguish handled accepted,
  handled rejection, handled no-op, accepted duplicate, and genuine failure;
  prove rejection/no-op acknowledge normally under the default halt policy;
  and verify payload text is absent from exported metrics. Workers dispatch
  through strict payload-free summaries rather than detailed result lists. The
  10, 100, and 1000 target router/process-manager benchmark fixtures compile;
  all 13 focused examples pass.
- [x] (2026-08-11T14:42:12Z) Milestone 3 performance acceptance: strengthened the worker fixtures so
  each accepted target constructs a distinct deterministic 1 KiB event payload
  from an integer command, rather than sharing one global `Text`. Relaxed-
  tolerance diagnostic runs at fan-out 10, 100, and 1000 kept maximum residency
  bounded at 8,189,480 bytes for the router and 8,579,784 bytes for the process
  manager while producing up to 1 MiB of distinct accepted payload per
  dispatch. Post-reboot one-dispatch RTS runs measured 2,215,584 bytes maximum
  residency for the router and 2,399,736 bytes for the process manager through
  fan-out 1000. Allocation scaled from 2.0 MB to 163 MB for the router and from
  1.8 MB to 139 MB for the process manager, while residency stayed bounded.
  The finished default-tolerance latency baseline also passed all fan-out rows.
- [x] (2026-08-10T19:18:03Z) Milestone 4 non-performance work: documented
  direct, SQL, projection, coordinator, retry, telemetry, payload-cardinality,
  duplicate, and memory-ownership semantics; added accepted ADR 0029; updated
  both changelogs and IR-7 without falsely completing its pending DSL scope;
  reconciled Plan 232 with the committed names; and added a database-backed
  Jitsurei example that exhaustively renders all three decisions and proves
  only accepted events reach inline projection SQL. `cabal build all`, all 456
  Keiro examples, all 674 core DSL examples plus every generated conformance
  executable, all 23 Jitsurei examples, strict ADR/IR validation, `nix fmt`,
  and `nix flake check -j1 --cores 1` pass.
- [ ] Milestone 4 performance-coupled closeout: after the machine reboots, run
  the default-tolerance command suite, create the finished command baseline,
  extend and run `just bench-regression`, and accept the result only after the
  Milestone 1 and 3 latency/allocation/residency checks pass. Keep IR-7 open for
  Plan 232 regardless of this runtime closeout.
- [ ] Follow-up: execute [the DSL plan](232-add-typed-domain-outcomes-to-the-dsl.md) after this runtime contract is stable.


## Surprises & Discoveries

- Discovery: Exact edge attribution does not add a second guard traversal. In the pinned
  Keiki 0.9 source, `stepEither` already delegates to `stepDetailedEither` and erases the
  successful `StepSuccess`; using the detailed form directly changes retained information,
  not the selection algorithm.

- Discovery: Retained memory is a more credible risk than command-evaluation CPU. Returning
  `NonEmpty co` extends the lifetime of accepted event values beyond append, and a detailed
  router/process-manager result can retain one such batch per target. The implementation
  therefore needs explicit heap/large-fan-out evidence rather than relying only on latency
  tests.

- Discovery: The first combined `+RTS -s` baseline run timed out only the
  `accepted-1` statistical case after 100 seconds even though the immediately
  preceding CSV run measured it at 3.12 ms. An isolated rerun completed in 3.42
  seconds with a 1.65 ms ± 126 μs sample, so the timeout was a benchmark-harness
  outlier rather than a reproducible command-path regression.
  Evidence: the combined run still completed `accepted-large` at 32.4 ms and
  `no-op` at 1.11 ms, and `cabal bench keiro-bench
  --benchmark-options="-p accepted-1 --time-mode wall +RTS -s -RTS"` exited 0.

- Discovery: Finished-code ratio samples taken later in the session were not
  usable because the user confirmed the computer was under heavy load. The
  instability was visible as an accepted-small standard deviation almost as
  large as its mean and repeated 100-second convergence stalls, while a focused
  no-op comparison measured identical 128 μs means and a 1.00x ratio.
  Evidence: the benchmark code retains hard `bcompareWithin 0 1.25` gates, but
  no committed baseline was created or changed from these noisy samples.

- Discovery: Lower foreground load was sufficient for stable isolated heap
  comparisons but not for trustworthy baseline replacement before a reboot.
  A read-only legacy comparison measured accepted-large at 27.9 ms ± 2.2 ms,
  32 percent above the scratch baseline, while a subsequent isolated legacy
  heap run measured 6.08 ms ± 565 μs and the matching typed run measured
  6.29 ms ± 338 μs. The user therefore required all baseline creation or
  changes to wait until after reboot.
  Evidence: accepted-1 and no-op ratio gates passed, but accepted-1 samples
  still showed deviations nearly as large as their means and the legacy hard
  guard failed accepted-large during the noisy combined run.

- Discovery: The original coordinator fixture reused one global 1 KiB `Text`
  across every accepted target, so it could detect wrapper accumulation but
  not retained payload batches. The corrected fixture sends only an integer
  target index and constructs a distinct deterministic 1 KiB event payload in
  the target transducer. With that stronger fixture and a deliberately relaxed
  statistical tolerance, router and process-manager maximum residency remained
  8.19 MB and 8.58 MB respectively through fan-out 1000.
  Evidence: router per-iteration allocation scaled 1.8 MB, 18 MB, and 181 MB;
  process-manager allocation scaled 1.7 MB, 16 MB, and 157 MB; neither retained
  the 10 KiB, 100 KiB, or 1 MiB of completed accepted payloads in its strict
  acknowledgement summary.

- Discovery: The typed catalog path needs a fourth transactional state beyond
  accepted, rejected, and no-op: an accepted append can be condemned by a
  rebuild fence before it commits. Returning that as `DomainAccepted` would
  falsely claim persistence metadata for an append that does not exist.
  Evidence: `DomainSqlCommandRolledBack` carries only the fence result, while
  the focused catalog test proves the event stream and target table remain
  unchanged.

- Discovery: The dispatch metrics recorder emits an explicit zero-valued
  `keiro.dispatch.failed` point for a successful worker message rather than
  omitting the point.
  Evidence: the domain worker test asserts `IntNumber 0` and separately proves
  that neither rejection nor no-op payload text appears in exported metrics.

- Discovery: Adding state-preserving silent cancellation behavior to the
  Jitsurei order transducer still changes its executable fold contract even
  though those edges emit no events and preserve state.
  Evidence: the example advances the hand-owned snapshot discriminator from
  `order-fold-v1` to `order-fold-v2`, and the full Jitsurei snapshot suite
  passes with the new discriminator.

- Discovery: A default-tolerance `+RTS -s` run is not valid post-dispatch heap
  evidence for these database-backed benchmarks. Tasty-bench adaptively doubles
  the number of action executions until it reaches its relative-deviation
  target, while both its displayed `peak memory` field and the RTS maximum
  residency cover the entire process run. Noisy short cases can therefore run
  thousands of append/delete cycles and report a large cumulative maximum that
  is unrelated to one returned outcome or one completed fan-out.
  Evidence: the router group initially reported 104,161,136 bytes maximum
  residency, but a non-router accepted-one control likewise reached 41,064,624
  bytes after allocating 4,984,906,512 bytes across its adaptive campaign. With
  `--stdev Infinity`, which tasty-bench documents as exactly one iteration per
  selected case, router and process-manager fan-out through 1000 retained only
  2,215,584 and 2,399,736 bytes respectively.


## Decision Log

- Decision: Treat typed rejection and typed no-op as successful domain decisions, not as
  new `CommandError` constructors.
  Rationale: They are expected application outcomes. Keeping them on the `Right` side
  preserves `Left CommandError` for failures that retry, halt, or require operator action.
  Date: 2026-08-10

- Decision: Derive typed rejection and no-op only from an explicitly selected, eventless,
  state-preserving live edge; keep `NoOutgoingEdges` and `NoMatchingEdge` mapped to the
  existing generic `CommandRejected`.
  Rationale: A second rejection function for unmatched guards would duplicate domain
  selection and could disagree with Keiki. An exact selected edge is a positive domain
  decision, while no matching edge still means the command protocol is partial.
  Date: 2026-08-10

- Decision: Add `DomainCommandHandler` and typed runners alongside `ValidatedEventStream`
  and `runCommand`; do not add result parameters to `EventStream`, `CommandResult`, or
  `CommandError`.
  Rationale: Parameterizing the foundational stream type would cause broad source and type
  inference breakage. The outcome policy belongs at the command-handling boundary.
  Date: 2026-08-10

- Decision: Return the exact accepted `NonEmpty co` batch already evaluated for append and
  never re-run the transducer to construct the result.
  Rationale: The caller must observe the same ordered values that were encoded and appended,
  and domain evaluation must retain one authority.
  Date: 2026-08-10

- Decision: Retry the whole hydrate-and-evaluate loop, returning only the final successful
  decision; never run SQL callbacks or projections for typed rejection or no-op.
  Rationale: A concurrency conflict makes the earlier decision stale. Eventless decisions
  have no append transaction to which side effects can be atomically attached.
  Date: 2026-08-10

- Decision: Add outcome-aware router and process-manager entry points rather than changing
  their existing result types in place.
  Rationale: Existing callers retain compatibility, while coordinators can treat domain
  rejection/no-op as handled and reserve retry/dead-letter policy for `CommandError`.
  Date: 2026-08-10

- Decision: Emit only the bounded telemetry dimension
  `keiro.command.decision = accepted | rejected | no_op`; never record a domain payload as a
  metric label, error type, span status description, or dead-letter reason.
  Rationale: Application reason values can be sensitive and high-cardinality, while the
  three-way class is operationally useful and bounded.
  Date: 2026-08-10

- Decision: Stabilize the runtime contract here and implement DSL syntax, generation, and
  conformance in the dependent [DSL ExecPlan](232-add-typed-domain-outcomes-to-the-dsl.md).
  Rationale: The runtime API is independently useful for handwritten aggregates and gives
  the generator a tested target instead of coupling two public surfaces in one rollout.
  Date: 2026-08-10

- Decision: Preserve the existing `runCommand*` path without constructing dummy domain
  outcomes, keep one shared typed event batch per attempt, and make workers consume detailed
  coordinator outcomes through a strict fold that drops handled payloads promptly.
  Rationale: The additive API must not tax callers that do not use it. A returned accepted
  batch necessarily lives as long as its result, but the runtime must not add a second full
  copy, retain `SilentCommandContext`, or multiply that lifetime inside long-running workers.
  Latency, allocation, maximum-residency, and high-fan-out scenarios will be measured before
  the performance work is accepted.
  Date: 2026-08-10

- Decision: Give the benchmark component a direct `keiki >=0.9 && <0.10`
  dependency for its in-component transducer fixture.
  Rationale: Cabal components cannot use Keiki constructors through Keiro's
  transitive library dependency. This repeats the repository's existing bound
  without adding or upgrading an external package, and keeps the benchmark
  aggregate independent of test-only fixtures.
  Date: 2026-08-10

- Decision: Give the benchmark component the same direct
  `aeson >=2.2.2 && <2.3` dependency as the Keiro library for the strengthened
  fan-out event codec.
  Rationale: Cabal components cannot import Aeson's `Result` constructors
  through `Keiro.Prelude`'s transitive library dependency. A real round-tripping
  codec keeps the heap fixture representative without changing any package
  bound or legacy benchmark scenario.
  Date: 2026-08-10

- Decision: Keep the unprefixed `SilentCommandContext` record labels `state`,
  `registers`, `command`, and `selectedEdge`, and define that record in the
  internal `Keiro.Command.Domain` module with `NoFieldSelectors`.
  Rationale: The user prefers unprefixed record fields. Suppressing selector
  functions only for this new record avoids making the established
  `Hydrated.state` and `Hydrated.registers` selector calls ambiguous, while
  record construction, pattern matching, overloaded labels, and record-dot
  access remain available for the new context.
  Date: 2026-08-10

- Decision: Represent controlled SQL execution with
  `DomainSqlCommandSilent`, `DomainSqlCommandCommitted`, and
  `DomainSqlCommandRolledBack`, and expose catalog results through the parallel
  `DomainProjectionCommandOutcome` family.
  Rationale: A silent decision is successful but opens no transaction, a
  committed accepted decision owns both its exact event batch and callback
  value, and a condemned append has neither a valid `CommandResult` nor a
  durable domain outcome to fabricate.
  Date: 2026-08-10

- Decision: Model telemetry's three allowed metric labels as the closed
  `CommandDecisionClass` type and render its text in `Keiro.Telemetry`.
  Rationale: Keeping the metric recorder typed prevents arbitrary application
  reason text from entering the decision dimension while spans and metrics
  share the exact stable spellings.
  Date: 2026-08-10

- Decision: Keep the process manager's own state transition on the established
  command runner while applying `DomainCommandHandler` only to its dispatched
  target aggregate.
  Rationale: The requested typed result belongs to target-command policy; the
  existing manager-state and timer transaction boundary remains compatible and
  still aborts the whole reaction through the outer `CommandError`.
  Date: 2026-08-10

- Decision: Summarize domain coordinator worker results immediately into only
  duplicate count and failure identity, while leaving the detailed one-shot
  APIs free to return every handled payload.
  Rationale: Callers explicitly asking for details own proportional memory, but
  acknowledgement policy needs no accepted, rejection, or no-op payload and
  must release each handled result before the next target.
  Date: 2026-08-10

- Decision: Keep IR-7 in `proposed` status after the handwritten runtime lands
  and record runtime progress in its body/log rather than marking the whole
  request completed.
  Rationale: Plan 232 still owns the requested DSL syntax, generation, and
  exact-reason conformance, while the current host also prevents honest
  performance closeout for this runtime plan.
  Date: 2026-08-10

- Decision: Use default statistical tolerance for latency comparisons and
  `--stdev Infinity` for RTS allocation/residency ownership checks.
  Rationale: Latency gates need repeated samples, while heap ownership asks how
  much remains live during one completed dispatch. Allowing tasty-bench to
  repeat a database-mutating action until a timing deviation converges measures
  the cumulative benchmark campaign instead of the one-dispatch retention
  contract and produced the same apparent growth without any router involved.
  Date: 2026-08-11


## Outcomes & Retrospective

The handwritten/runtime surface is functionally implemented across direct
commands, SQL, inline/catalog projections, optimistic retries, bounded
telemetry, routers, and process managers. Existing entry points remain
additive, and the Jitsurei proof demonstrates application-level exhaustive
handling without projection effects for typed silent decisions. ADR 0029 now
records the durable contract, while Plan 232 names the exact generated target.

The remaining work is deliberately evidence-only and reboot-gated: stable
default-tolerance latency measurements, the committed command baseline, its
`Justfile` guard, and `just bench-regression`. Isolated heap diagnostics already
show that the large accepted outcome adds only one typed batch and that the
strict router/process-manager summaries remain bounded through fan-out 1000,
including after strengthening the fixture to create distinct 1 KiB payloads.
The user's machine nevertheless produced contradictory combined latency runs,
and the user explicitly deferred every baseline creation or change until after
a reboot. The scratch pre-refactor CSV remains unchanged and uncommitted. Until
those post-reboot checks pass, this plan is not fully closed even though all
functional, documentation, Cabal, OKF, formatting, and Nix validation succeeds.


## Context and Orientation

The source request is
[`docs/improvement-requests/return-typed-domain-command-outcomes-and-rejection-details.md`](../improvement-requests/return-typed-domain-command-outcomes-and-rejection-details.md).
It asks for typed accepted, rejected, and no-op outcomes across direct command execution,
projections, coordinators, telemetry, and the DSL. This plan owns the handwritten/runtime
surface. [Plan 232](232-add-typed-domain-outcomes-to-the-dsl.md) is the dependent language
and generator change.

`keiro-core/src/Keiro/EventStream.hs` defines the five-parameter
`EventStream phi rs s ci co`. It describes persistence, hydration, and the Keiki
transducer. `keiro-core/src/Keiro/EventStream/Validate.hs` wraps it in
`ValidatedEventStream` after structural validation. Neither type currently has an
application result or rejection parameter, and this plan deliberately leaves both stable.

`keiro/src/Keiro/Command.hs` is the central execution path. `CommandResult target` reports
the target stream, resulting stream version, optional global position, and append count.
`CommandError` distinguishes hydration, generic rejection, ambiguity, encoding, store,
retry-exhaustion, and conflict-fixpoint failures. `evaluateCommand` calls `Keiki.stepEither`;
it maps `NoOutgoingEdges` and `NoMatchingEdge` to the nullary `CommandRejected`, maps
ambiguous matches to `CommandAmbiguous`, and otherwise returns a list of events.
`prepareCommandPlan` interprets an empty list as `CommandNoOp`; a non-empty list is encoded
and appended. `runCommand` retries optimistic conflicts. `runCommandWithSql`,
`runCommandWithSqlEvents`, and `runCommandWithSqlEventsControlled` add transactional
callbacks, which are already skipped for a no-op.

The Keiki dependency is the registered package
`mori://shinzui/keiki/packages/keiki`. Its released version 0.9.0.0 already exports
`stepDetailedEither`, `StepSuccess`, and `EdgeRef`. A successful step contains the exact
selected edge, post-state, post-register file, and ordered output word. `stepEither` is only
an erasing projection of this detailed result. Keiro already declares `keiki >=0.9 && <0.10`
and pins the release commit `9714d37033c37595e3aaa3319ca0ca77466782e0` in
`cabal.project`; no dependency or bound change is needed. This was checked against the
Hackage 0.9.0.0 release and the upstream `v0.9.0.0` tag, not inferred from the local corpus.

In this plan, a *silent edge* means a Keiki `Live` edge whose selected output word is empty.
For it to represent a domain rejection or no-op, it must also preserve durable aggregate
state. `ValidatedEventStream` already force-enables Keiki's state-changing-epsilon check, so
the ordinary validated construction boundary enforces that invariant; the documented
unchecked escape hatch retains its existing test/forensics caveat. The runtime classifier
receives an exact `EdgeRef` plus execution context and produces one typed silent decision.
An unmatched command has no selected edge and is therefore not a typed business decision.

`keiro/src/Keiro/Projection.hs` builds inline and catalog-controlled projection runners on
the SQL command callbacks. The new outcome-aware variants must keep the same atomicity for
accepted commands and must not call projection code for rejection or no-op.

`keiro/src/Keiro/ProcessManager.hs` currently represents target execution as
`PMCommandAppended CommandResult`, `PMCommandDuplicate EventId`, or
`PMCommandFailed StreamName CommandError`. Workers classify generic `CommandRejected` using
`RejectedCommandPolicy`. `keiro/src/Keiro/Router.hs` reuses the same result and failure
machinery. Additive domain-aware coordinator result types are required because the current
ones cannot carry application payloads. Duplicate detection remains a separate result:
after redelivery, an event id proves that an accepted command already ran but cannot
reconstruct the original in-memory `co` values without decoding stored events. Eventless
rejection/no-op has no durable idempotency record and may be safely re-evaluated.

`keiro/src/Keiro/Telemetry.hs` and the span helpers in `Keiro.Command` currently record
append counts, retry counts, duplicates, conflicts, and low-cardinality error classes.
Typed rejection/no-op must leave span status successful and add only the bounded decision
class. Payloads remain available to the caller but absent from operational labels.

`keiro/bench/Main.hs` and the `keiro-bench` stanza in `keiro/keiro.cabal` provide the
repository's `tasty-bench` integration point. `Justfile` already guards committed inbox and
outbox CSV baselines with `--fail-if-slower 25`; command benchmarks should use the same
mechanism. The legacy runner currently stops retaining typed events when it returns, whereas
the new accepted result intentionally retains them. That user-visible ownership cost is
unavoidable, but copying the whole batch, retaining the hydrated register file or command
behind a lazy reason, or accumulating all detailed results inside a worker is avoidable.
Here, *maximum residency* means the largest amount of heap that remains live during a run,
as reported by GHC's `+RTS -s` statistics. It is the evidence used alongside wall-clock time
to distinguish intentional result ownership from accidental retention.

The registered Kiroku package `mori://shinzui/kiroku/packages/kiroku-store` exposes
`Kiroku.Store.Lifecycle.hardDeleteStream`, which permanently removes one named stream through
the supported store effect while respecting Kiroku's protected deletion contract. Command
benchmarks use that function on their exact dedicated stream before each measured command;
they must not truncate or delete Kiroku's protected tables directly.

The public behavior is described in `docs/user/command-cycle.md`,
`docs/user/api-reference.md`, `docs/user/operations.md`, and
`docs/user/process-managers-and-timers.md`. The Jitsurei examples are the executable place
to demonstrate application handling after unit coverage.

The relevant architectural constraints are:

- [ADR 0002](../adr/0002-replay-only-edges-are-the-sanctioned-remedy-for-guard-tightening.md)
  excludes replay-only edges from forward commands; a typed domain decision must come from
  a live edge.
- [ADR 0004](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
  requires validation at the earliest sound lifecycle boundary, with runtime defense where
  malformed values can still be constructed by hand.
- [ADR 0016](../adr/0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md)
  freezes published DSL languages and permits correction of candidate language 5. It is
  chiefly applied by the follow-up plan.
- [ADR 0017](../adr/0017-aggregate-transitions-have-explicit-generated-or-hole-behavior-ownership.md)
  establishes exact `EdgeRef` attribution and rejects eventless state changes. The runtime
  outcome boundary builds on the same identity and invariant.
- [ADR 0018](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md) and
  [ADR 0020](../adr/0020-service-conformance-packages-import-one-runtime-owned-facade.md)
  constrain the follow-up generator and conformance package.

No existing ADR decides whether business rejection is a successful public command result,
how accepted typed events are returned, or how the result flows through coordinators. The
implementation must create an ADR for that durable contract during Milestone 4; its numeric
identifier must be allocated at that time rather than guessed in this plan.


## Plan of Work

### Milestone 0: command performance baseline

Before changing `Keiro.Command`, extend `keiro/bench/Main.hs` with a small validated command
aggregate and three legacy `runCommand` scenarios: one accepted event, a large accepted batch
with fixed-size payloads, and a selected zero-event no-op. Give them names under
`command.legacy`. Reset each benchmark stream inside the measured action in the same
repeatable way by calling `Kiroku.Store.Lifecycle.hardDeleteStream` on that exact dedicated
stream before running the command, and prebuild commands and codecs outside the measured
action. The constant reset cost appears on both sides of the comparison. Do not issue direct
`DELETE` or `TRUNCATE` against Kiroku tables. Build the existing `keiro-bench` component; no
new benchmark dependency or component is needed.

Record a scratch before CSV and the `+RTS -s` allocation/maximum-residency transcript before
the production refactor. Note the machine, compiler, and PostgreSQL fixture in Progress when
capturing evidence. The scratch before CSV is implementation evidence, not a committed
baseline. This milestone is complete when all three scenarios run repeatedly and the before
artifacts have been recorded while `runCommand` is still unchanged.

### Milestone 1: typed values and the direct runner

Extend `keiro/src/Keiro/Command.hs` with `DomainDecision`, `DomainCommandOutcome`,
`SilentCommandContext`, `SilentDomainDecision`, and `DomainCommandHandler`. The handler owns
a validated event stream and one classifier for already-selected silent edges. Keep the
classifier pure. Use `Keiki.stepDetailedEither` exactly once per attempt: map step failure to
the existing `CommandError`; turn a non-empty output word into `DomainAccepted`; and invoke
the classifier only for an empty output word. The existing `ValidatedEventStream` boundary
continues to reject state-changing epsilon edges. Make the classifier total, so every
selected silent edge is deliberately either rejection or no-op.

Refactor the internal `CommandPlan` so an append retains the same `NonEmpty co` used to
build `EventData`, while an eventless plan retains its typed silent decision. Build
`runDomainCommand` on the same hydration, optimistic-concurrency, verification, and snapshot
machinery as `runCommand`. A conflict discards the whole attempted decision and rehydrates.
Add `forgetDomainDecision` so all three successfully selected decisions collapse to their
`CommandResult`. Applied under the runner's outer `Either`, this exactly matches the current
behavior: any matched eventless edge is a successful zero-append command, while genuinely
unmatched commands remain `Left CommandRejected`. Turning a typed rejection back into an
error is application policy and is not labeled as compatibility.

Keep `runCommand` and the existing SQL runners on a legacy result path that does not allocate
`DomainDecision`, `DomainCommandOutcome`, a dummy classifier, or typed reason values. A
shared internal attempt engine is acceptable, but it must be result-polymorphic or otherwise
specialized so the old path does not manufacture and immediately erase the new wrappers.
When converting Keiki's non-empty output list, share its tail with `NonEmpty` and store one
typed batch in the command plan; do not retain independently copied `[co]` and `NonEmpty co`
containers. Encoded `EventData` is necessarily separate and should be released after append.
After `classifySilent` returns, retain only its strict reason/no-op value plus
`CommandResult`; never store `SilentCommandContext`, hydrated state/registers, or the command
inside `DomainCommandOutcome`. Handwritten classifiers remain responsible for the contents
of their own payload values, while generated scalar classifiers are covered by Plan 232.

Add focused tests in `keiro/test/Main.hs` or a dedicated neighboring test
module. Cover ordered accepted events, exact edge attribution between sibling silent edges,
typed rejection, typed no-op, unmatched and ambiguous errors, validated rejection of an
eventless state change, and the compatibility adapter. Existing `runCommand` tests must
continue unchanged. Add after-only `command.domain.accepted-1`,
`command.domain.accepted-large`, `command.domain.rejected`, and `command.domain.no-op`
benchmarks alongside the legacy scenarios. Use `Test.Tasty.Bench.bcompareWithin` with an
upper ratio of `1.25` to compare accepted-small/accepted-large to their legacy eventful
counterparts and rejection/no-op to the legacy selected no-op on the same finished-code run.
This milestone is complete when the focused tests and `cabal build keiro` pass, every ratio
gate passes, and the old path's benchmark shape still contains no domain-wrapper work.

### Milestone 2: SQL, projections, retries, and telemetry

Add `runDomainCommandWithSql`, `runDomainCommandWithSqlEvents`, and, if catalog fencing needs
it, a controlled transaction variant in `keiro/src/Keiro/Command.hs`. Accepted commands run
the callback with the exact `(co, RecordedEvent)` pairs and commit atomically. Typed
rejection/no-op returns `Nothing` for the callback value and performs no SQL callback,
projection, replay verification, or snapshot write because there is no append.

Add outcome-aware projection helpers in `keiro/src/Keiro/Projection.hs`, including the
catalog-controlled path used by generated service facades. Preserve the current catalog
rollback behavior for accepted appends and surface the domain outcome around its existing
catalog result. Do not change existing projection functions or their result shapes.

Update the command span recording in `keiro/src/Keiro/Command.hs` and metrics support in
`keiro/src/Keiro/Telemetry.hs`. Record the bounded decision class on successful outcomes.
An application payload must not enter `error.type`, a metric attribute, span description,
or structured log. Add a deterministic conflict test in which the first evaluation accepts,
the append conflicts, and the rehydrated attempt returns rejection/no-op; assert that the
returned decision is the latter and no transactional callback ran. The existing
`beforeAppend` test hook may run for an accepted attempt that later conflicts, so document
that it is a test/observation hook rather than an application transaction callback.

This milestone is complete when command, projection, catalog, retry, and telemetry tests
prove both accepted atomicity and absence of side effects for silent decisions.

### Milestone 3: routers and process managers

In `keiro/src/Keiro/ProcessManager.hs`, add domain-aware target configuration and parallel
result types capable of carrying `DomainCommandOutcome`. Add domain-aware one-shot and worker
entry points without changing `ProcessManager`, `PMCommandResult`, or current workers. A
typed rejection/no-op is a handled dispatch and produces `AckOk`; it does not invoke
`RejectedCommandPolicy`, retry, or create a dead letter. A `CommandError` continues through
the current transient, systemic, rejection-class, and poison policy.

Represent a previously accepted deterministic-id duplicate separately from a fresh typed
outcome and document that it cannot reconstruct `NonEmpty co`. Re-evaluate eventless
decisions on redelivery because they leave no event id. Preserve the manager-state and timer
transaction boundaries.

Apply the same additive pattern in `keiro/src/Keiro/Router.hs`: domain-aware router
configuration, result, one-shot runner, and worker. Preserve target resolution order,
deterministic ids, per-target transaction boundaries, and duplicate confirmation. Extend
tests in the existing process-manager and router suites with payload-carrying rejection and
no-op cases and assertions that no failure metric or dead letter contains the payload.

Implement the internal domain-aware dispatch loop as a strict fold over target commands.
The detailed one-shot APIs may accumulate their documented result lists, whose live memory is
necessarily proportional to the accepted events they return. Worker entry points must use a
summary accumulator containing only acknowledgement/failure information and must release each
handled `DomainCommandOutcome` before dispatching the next target; they must not call the
detailed list-returning convenience API and then discard its payloads. Add router and
process-manager benchmark cases at fan-out 10, 100, and 1000 with fixed-size accepted payloads
so time and maximum residency expose accidental whole-result accumulation.

This milestone is complete when direct coordinator tests show accepted, rejection, no-op,
duplicate, and genuine failure as five distinguishable cases and worker tests prove the
acknowledgement policy. The worker heap evidence must also show that post-dispatch retained
payload memory does not grow with completed handled targets; the detailed one-shot result is
allowed and documented to grow with the payloads it returns.

### Milestone 4: public documentation, ADR, and release validation

Update `docs/user/command-cycle.md` and `docs/user/api-reference.md` with the outcome model,
signatures, compatibility adapter, retry semantics, and the distinction between a selected silent
edge and an unmatched command. Update `docs/user/operations.md` with the telemetry and
payload-cardinality rules. Extend `docs/user/api-reference.md` and
`docs/user/process-managers-and-timers.md` with router and process-manager handling and the
duplicate limitation.
Add a small Jitsurei example that pattern-matches all three decisions and demonstrates that
only accepted events reach its inline projection.

Document that accepted outcomes own their returned event values until the caller releases
the result, and that detailed one-shot coordinator results have memory proportional to all
returned accepted batches. Include the worker's bounded-retention behavior and recommend
worker/streamed processing rather than retaining detailed high-fan-out results when only an
acknowledgement summary is needed.

Allocate and write an ADR under `docs/adr/` that records the durable runtime contract:
business rejection/no-op are successful domain results, exact selected edges are the
classification authority, infrastructure and unmatched failures remain `CommandError`, and
old APIs stay additive. Update package changelogs. Only after all acceptance checks pass,
update the improvement request status and progress while leaving its DSL portion linked to
[Plan 232](232-add-typed-domain-outcomes-to-the-dsl.md) until that follow-up completes.

This milestone is complete when documentation examples compile, ADR and improvement-request
bundles validate, the full Cabal/Nix suite passes, and the follow-up plan still names the
exact runtime interfaces actually delivered.


## Concrete Steps

Run every command from the repository root,
`/Users/shinzui/Keikaku/bokuno/keiro`. After adding only the Milestone 0 benchmark fixture,
capture the unchanged legacy baseline before editing production command code:

```bash
cabal build keiro:bench:keiro-bench
cabal bench keiro-bench \
  --benchmark-options="-p command --time-mode wall --csv bench-command-before.csv"
cabal bench keiro-bench \
  --benchmark-options="-p command --time-mode wall +RTS -s -RTS"
```

Cabal runs the executable with `keiro/` as its package directory, so the scratch CSV appears
as `keiro/bench-command-before.csv`. It must contain the three `command.legacy` scenarios.
Save the RTS lines for total allocation and maximum residency in Progress together with the
machine/compiler note. Do not commit the scratch CSV.

Start each implementation milestone with the narrow build and tests:

```bash
cabal build keiro
cabal test keiro-test --test-show-details=direct \
  --test-option=--match \
  --test-option='typed domain command outcomes'
```

The focused transcript must end in successful examples for direct commands, SQL/projection
execution, retries, router dispatch, and process-manager dispatch, with no failed examples.
If the test runner's final names differ, update the filter here to the committed test labels
rather than running a filter that selects zero tests.

After Milestone 3, capture the complete command baseline, compare the unchanged legacy
scenarios to the scratch before file using the repository's existing 25-percent hard guard,
and collect heap evidence for the large-batch and high-fan-out cases:

```bash
cabal bench keiro-bench \
  --benchmark-options="-p command --time-mode wall --csv bench/baseline-command.csv"
cabal bench keiro-bench \
  --benchmark-options="-p command.legacy --time-mode wall \
    --baseline bench-command-before.csv --fail-if-slower 25"
cabal bench keiro-bench \
  --benchmark-options="-p command.domain.accepted-large --time-mode wall --stdev Infinity +RTS -s -RTS"
cabal bench keiro-bench \
  --benchmark-options="-p command.domain.router-fanout --time-mode wall --stdev Infinity +RTS -s -RTS"
cabal bench keiro-bench \
  --benchmark-options="-p command.domain.process-manager-fanout --time-mode wall --stdev Infinity +RTS -s -RTS"
just bench-regression
```

Extend `Justfile`'s `bench-regression` recipe with the committed
`keiro/bench/baseline-command.csv` using the same `--fail-if-slower 25` convention. The
legacy comparison and `just bench-regression` must exit successfully. Record the domain
scenario timings, allocation, and maximum residency rather than treating them as pass/fail
noise. If the large accepted result shows a second full payload-sized copy, or worker
post-dispatch residency grows with completed fan-out, profile and remove the retention before
continuing. The detailed one-shot fan-out benchmark may grow in proportion to the returned
payload and should be labeled separately from the bounded worker scenario.

Before creating the ADR, discover the allocated identifiers and validate the result:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf log add --help
just adr-validate
```

Use the identifier printed by `okf id next`; do not reserve one in advance. Use the log
command form reported by the installed CLI. `just adr-validate` must finish successfully.

Validate the improvement-request bundle after updating the request:

```bash
okf validate docs/improvement-requests --strict \
  --profile mori/improvement-requests-profile.dhall \
  --profile-enforce --log-enforce
```

Finish with the repository-wide checks:

```bash
cabal build all
cabal test keiro-test --test-show-details=direct
cabal test keiro-dsl:tests --test-show-details=direct
cabal test jitsurei-test --test-show-details=direct
just bench-regression
just adr-validate
nix fmt
nix flake check
git diff --check
git status --short
```

Expected final evidence is successful Cabal and Nix exits, no output from
`git diff --check`, and a `git status --short` containing only the intended implementation,
documentation, ADR, plan, and generated fixture changes plus any unrelated pre-existing
user changes.


## Validation and Acceptance

Acceptance requires all of the following observable behavior, not merely compilation:

1. Given a command whose selected live edge emits `[e1, e2]`, `runDomainCommand` returns
   `Right` with `DomainAccepted (e1 :| [e2])`; those same values encode to two stored events
   in order, and `CommandResult.eventsAppended` is `2` with the committed stream/global
   positions.
2. Given sibling silent edges with distinct exact `EdgeRef`s, the classifier returns the
   reason attached to the edge Keiki selected. A counter or bottom placed behind any second
   selection path proves the domain decision is not recomputed.
3. Given explicit state/register-preserving silent edges, typed rejection and no-op return
   `Right` with their payload and a `CommandResult` containing zero appends, the unchanged
   stream version, and no global position. Neither executes append callbacks, SQL callbacks,
   projections, snapshots, router targets, process-manager targets, or timers attributable
   to the target command.
4. Given no outgoing edge, no matching live edge, multiple matching edges, decode failure,
   encode failure, or store failure, the result remains the corresponding `CommandError`.
   None is forged into an application payload.
5. Given a forced concurrency conflict followed by a different valid decision after
   rehydration, only the final decision is returned. No SQL callback or projection from the
   discarded attempt commits.
6. `forgetDomainDecision` maps accepted, typed rejection, and no-op to the historical
   successful `CommandResult`, because all came from a matched edge. Applied with `fmap` to
   `runDomainCommand`, unmatched `CommandRejected` and every other existing error remain on
   the outer `Left`; all pre-existing `runCommand*` source and behavior tests pass unchanged.
7. Domain-aware router and process-manager results preserve the application payload and
   acknowledge rejection/no-op as handled. Genuine `CommandError` follows existing policy.
   A confirmed accepted duplicate remains distinguishable and does not claim to reconstruct
   the original typed event batch.
8. Spans and metrics expose only `accepted`, `rejected`, or `no_op`. Payload text never
   appears in a metric label, error classification, span error description, or dead-letter
   record; typed rejection/no-op does not mark the span as an error.
9. A handwritten aggregate can construct a `DomainCommandHandler` without importing DSL
   modules, demonstrating that this plan is independently useful.
10. Published runtime behavior remains compatible: ordinary eventful, generic rejection,
    ambiguity, no-op, SQL, projection, router, and process-manager tests all still pass.
11. The public guides explicitly distinguish domain rejection from unmatched commands and
    state that eventless decisions do not provide a transaction for durable side effects.
12. The new ADR and improvement-request record pass strict OKF validation, and every final
    command in Concrete Steps exits successfully.
13. Every `command.legacy` scenario passes the before/after
    `--fail-if-slower 25` comparison, proving the additive refactor did not impose a material
    regression on callers that continue using `runCommand*`. On the same finished-code run,
    the small accepted, rejection, and no-op domain scenarios remain within 25 percent of
    their equivalent legacy path; any exception must be investigated and recorded rather
    than silently refreshing the baseline.
14. Heap evidence shows that a large accepted outcome retains one typed event batch plus
    fixed result metadata, not a second copied batch or its `SilentCommandContext`. Detailed
    one-shot coordinator residency grows only with the results it returns. Domain-aware
    workers complete fan-out 10, 100, and 1000 without post-dispatch retained payload memory
    growing with already handled targets, and `just bench-regression` enforces the committed
    command baseline for future changes.


## Idempotence and Recovery

This change has no schema migration and all build, test, formatting, and validation commands
are safe to repeat. The new API is additive, so a partial implementation can be recovered by
finishing one milestone without rewriting existing call sites. Preserve unrelated dirty
work and use `git diff -- <path>` before changing any overlapping file; do not use destructive
Git commands to recover.

The optimistic-retry tests must use isolated streams and deterministic synchronization so a
failed run leaves no fixture state that affects the next run. Generated documentation or
example output should be recreated with the same command rather than hand-repaired.

Benchmark actions must reset their own streams and are safe to repeat. Keep
`keiro/bench-command-before.csv` only until the same-machine comparison is recorded; it is a
scratch artifact and can be regenerated only from an unchanged pre-refactor checkout. The
committed `keiro/bench/baseline-command.csv` describes the finished implementation and may
be refreshed later only after investigating and documenting every reported regression.

A typed accepted result is reconstructible only during the attempt that appended it. Do not
add a cache or database schema solely to recover the original `co` batch for coordinator
duplicates. Typed rejection/no-op is not durably memoized and may be re-evaluated after a
crash; the classifier must therefore remain pure and free of side effects.

Do not mark the improvement request implemented while the dependent DSL plan remains
unfinished; record runtime completion precisely and retain the link. Once an ADR identifier
has been allocated and logged, never recycle it if validation fails. Correct that ADR in
place and rerun `just adr-validate`.


## Interfaces and Dependencies

`Keiro.Command` must export additive types with this semantic shape. Field names may be
adjusted to avoid the project's overloaded-record-field collisions, but the information and
strictness must remain:

```haskell
data DomainDecision co rejection noOp
  = DomainAccepted !(NonEmpty co)
  | DomainRejected !rejection
  | DomainNoOp !noOp

data DomainCommandOutcome target co rejection noOp = DomainCommandOutcome
  { decision :: !(DomainDecision co rejection noOp),
    result :: !(CommandResult target)
  }

data SilentCommandContext rs s ci = SilentCommandContext
  { state :: !s,
    registers :: !(RegFile rs),
    command :: !ci,
    selectedEdge :: !(EdgeRef s)
  }

data SilentDomainDecision rejection noOp
  = SilentRejected !rejection
  | SilentNoOp !noOp

data DomainCommandHandler phi rs s ci co rejection noOp = DomainCommandHandler
  { eventStream :: !(ValidatedEventStream phi rs s ci co),
    classifySilent :: !(SilentCommandContext rs s ci -> SilentDomainDecision rejection noOp)
  }
```

`NonEmpty` comes from `Data.List.NonEmpty`. `EdgeRef`, `RegFile`, and
`stepDetailedEither` come from `mori://shinzui/keiki/packages/keiki`. The classifier sees the
pre-command hydrated values and the exact selected edge. It does not select an edge, inspect
failed guards, perform IO, or evaluate the transducer again. `ValidatedEventStream` remains
the replay-safety authority for eventless state preservation.

The direct and compatibility functions must have these result shapes:

```haskell
runDomainCommand ::
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  Eff es
    (Either
      CommandError
      (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp))

forgetDomainDecision ::
  DomainCommandOutcome target co rejection noOp ->
  CommandResult target
```

Retain the constraints currently required by `runCommand`, including `BoolAlg`, `Eq co`,
store effects, and call-stack/IO constraints. The implementation may introduce an internal
shared attempt engine, but existing `runCommand` and `evaluateCommand` behavior must not be
defined by fabricating application reason types.

The transaction variants must parallel the current callback forms:

```haskell
runDomainCommandWithSql ::
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  (AppendResult -> Tx.Transaction a) ->
  Eff es
    (Either
      CommandError
      (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp, Maybe a))

runDomainCommandWithSqlEvents ::
  RunCommandOptions ->
  DomainCommandHandler phi rs s ci co rejection noOp ->
  Stream (EventStream phi rs s ci co) ->
  ci ->
  ([(co, RecordedEvent)] -> AppendResult -> Tx.Transaction a) ->
  Eff es
    (Either
      CommandError
      (DomainCommandOutcome (EventStream phi rs s ci co) co rejection noOp, Maybe a))
```

The `Maybe a` is `Just` only for a committed accepted append. If catalog rollback requires a
controlled variant, mirror `SqlTransactionDecision` and keep a rolled-back append distinct
from all three committed domain decisions.

`Keiro.Projection` must export `runDomainCommandWithProjections` and an outcome-aware
catalog runner. Both return the same `DomainCommandOutcome`; accepted carries catalog and
projection results according to the existing runner contract, while rejection/no-op carries
no fabricated projection result.

`Keiro.ProcessManager` and `Keiro.Router` must expose parallel configuration and result
families rather than add parameters to existing types. At minimum, their target result has
this distinction:

```haskell
data DomainPMCommandResult target co rejection noOp
  = DomainPMCommandHandled !(DomainCommandOutcome target co rejection noOp)
  | DomainPMCommandDuplicate !EventId
  | DomainPMCommandFailed !StreamName !CommandError
```

Export corresponding `DomainProcessManager`, `DomainRouter`, one-shot runners, configurable
workers, and default workers. A `DomainPMCommandHandled` value whose nested decision is
`DomainRejected` or `DomainNoOp` maps to `AckOk`; only `DomainPMCommandFailed` enters current
failure policy.

Telemetry adds one stable attribute key, `keiro.command.decision`, whose complete value set
is `accepted`, `rejected`, and `no_op`. It introduces no serializer or `Show` constraint for
application payloads.

No new external package is required. Keep the existing `keiki >=0.9 && <0.10` bound and
release pin. The follow-up DSL plan depends on the exported names committed here and must be
updated if implementation-driven naming changes occur.

The benchmark fixture uses only the already-present
`mori://shinzui/kiroku/packages/kiroku-store` dependency and its public
`Kiroku.Store.Lifecycle.hardDeleteStream` operation to reset a dedicated stream. It does not
change the Kiroku bound or depend on protected table names.

The strict fields above force each result constructor and payload to weak-head normal form,
but the library must not deep-force arbitrary application payloads or add an `NFData`
constraint. The runtime's retention guarantee is narrower and testable: it stores no
`SilentCommandContext` after classification and only one typed accepted batch. The detailed
one-shot coordinator API owns every result it returns; worker implementations instead use an
internal strict summary fold and do not retain handled domain payloads.

Revision note (2026-08-10): Added a pre-refactor command benchmark milestone, legacy
fast-path and single-batch allocation rules, strict-context lifetime requirements,
large-batch and coordinator fan-out heap evidence, a committed regression baseline, and
bounded worker accumulation after the performance review identified retained memory as the
primary risk.

Revision note (2026-08-10): Recorded Milestones 0 and 1 implementation evidence,
corrected the focused Hspec invocation to preserve its space-containing match as one
argument, kept unprefixed silent-context record labels without adding colliding selector
functions, and deferred all baseline generation or changes until the user's machine is no
longer under heavy load.

Revision note (2026-08-10): Recorded Milestone 2's typed SQL, projection,
catalog-fence, retry-finality, and closed telemetry interfaces and their focused
database-backed evidence. Functional validation used one build job under host
load; no benchmark result or baseline was created or changed.

Revision note (2026-08-10): Recorded Milestone 3's additive domain router and
process-manager interfaces, five-way coordinator behavior, strict worker
summaries, payload-free acknowledgement telemetry, and compile-only fan-out
fixtures. Kept heap/performance acceptance pending a quiet host and left every
benchmark baseline untouched.

Revision note (2026-08-10): Recorded Milestone 4 documentation, ADR 0029,
changelogs, partial IR-7 reconciliation, exact Plan 232 interface names,
Jitsurei proof, and full non-performance Cabal/OKF/Nix validation. Split final
closeout from functional completion so the required benchmark and residency
evidence remains pending a quiet host without changing any baseline.

Revision note (2026-08-10): Recorded stable isolated large-batch allocation and
residency evidence, strengthened coordinator fan-out to construct distinct
per-target 1 KiB event payloads, and recorded bounded relaxed-tolerance heap
diagnostics through fan-out 1000. Kept all default-tolerance latency gates,
baseline creation, and `just bench-regression` pending the user-requested
machine reboot after contradictory combined-run timings.

Revision note (2026-08-11): Recorded the post-reboot latency and legacy guards,
investigated an apparent router residency leak, and separated adaptive latency
sampling from one-dispatch heap ownership evidence. The non-router control
showed the same cumulative RTS growth under repeated database mutation, while
single-dispatch router and process-manager runs remained bounded through 1000
distinct accepted payloads.
