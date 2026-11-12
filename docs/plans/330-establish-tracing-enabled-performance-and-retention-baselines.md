---
id: 330
slug: establish-tracing-enabled-performance-and-retention-baselines
title: "Establish tracing-enabled performance and retention baselines"
kind: exec-plan
created_at: 2026-11-12T04:43:48Z
intention: "intention_01m770wgzbe9vakycrq50yq7th"
master_plan: "docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T04:43:48Z
---

# Establish tracing-enabled performance and retention baselines

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Keiro is about to record OpenTelemetry trace context on the events it appends and to attach
span links wherever work continues across a durable boundary (see the parent MasterPlan,
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`).
That work must not slow Keiro down or leak memory. Today this cannot be checked for the
tracer-enabled path: `keiro-bench` builds a metrics provider but never a tracer, and the
`keiro-retention` heap suite runs without one.

After this plan, a maintainer can run benchmark cells and retention legs that exercise the
command path, the outbox publisher, a subscription worker and a workflow run with a tracer
configured, alongside the existing no-tracer ones. This plan changes no library behaviour; it
produces the "before" measurement and the commit that later plans use as their baseline.


## Progress

- [ ] M1: `keiro-bench` has tracer-enabled cells for the command path, outbox publish, and
  process-manager dispatch, each next to its no-tracer counterpart, and they run.
- [ ] M2: `keiro-retention` has tracer-enabled legs for a command loop, a subscription worker
  and the outbox publisher, each ending in a `Bounded` verdict on unchanged library code; one
  leg has been shown to fail under a deliberately introduced retention bug.
- [ ] M3: Baseline numbers and the reproduction procedure are recorded under
  `keiro/bench/results/` and described where the existing baselines are described.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Tracer-enabled cells use a real tracer from a provider with no span processors.
  Rationale: The cost under test is Keiro's and the SDK's span and context work, not an
  exporter. A provider without processors creates recording spans under the default sampler
  with no I/O. Retention legs that must show a span not retaining data use the in-memory
  exporter instead, so finished spans stay referenced.
  Date: 2026-11-11

- Decision: New cells and legs are added beside the existing ones, never replacing or renaming
  them.
  Rationale: ADR-58 requires baselines whose changes have attributed causes; renaming a cell
  severs its history.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Keiro is a Haskell event-sourcing framework. Run everything inside the Nix development shell,
as `AGENTS.md` at the repository root requires (`nix develop -c …`).

The benchmark is the `benchmark keiro-bench` stanza in `keiro/keiro.cabal`, with sources in
`keiro/bench/` (`Main.hs`, `BenchSetup.hs`, `CommandProbe.hs`, `InboxDelegatedBench.hs`,
`ProducerIdentityBench.hs`, `ReadModelBench.hs`, the `GuardedCatalog*` modules) and checked-in
baselines `keiro/bench/baseline-{command,inbox,outbox,projection,read-model}.csv` with further
evidence under `keiro/bench/results/`, including `results/release-gates/`. `Main.hs` builds a
meter provider and a `KeiroMetrics` value; no module builds a tracer. Read `BenchSetup.hs` to
see how a store and fixtures are provisioned.

The heap-retention gate is the `test-suite keiro-retention` stanza (run with
`cabal test keiro-retention`, RTS options `-N -T`), sources in `keiro/retention/` (`Main.hs`,
`Retention/Legs.hs`, `Retention/Measure.hs`, `Retention/Fixture.hs`). A *leg* is one isolated
workload run against a fresh store; the suite measures live heap after major collections and
asserts a `Bounded` verdict. Legs are selected with the `KEIRO_RETENTION_LEGS` environment
variable.

A tracer is an OpenTelemetry `Tracer` from `hs-opentelemetry-api`. Keiro takes it as an optional
field: `RunCommandOptions.tracer` (`keiro/src/Keiro/Command.hs`), `OutboxPublishOptions.tracer`
(`keiro/src/Keiro/Outbox/Types.hs`), `WorkflowRunOptions.tracer` (`keiro/src/Keiro/Workflow.hs`).
`Nothing` makes every span helper in `keiro/src/Keiro/Telemetry.hs` a pass-through. The test
suite `keiro/test/Main.hs` already builds tracers with
`createTracerProvider [processor] emptyTracerProviderOptions` and `makeTracer`, using
`inMemoryListExporter` from `hs-opentelemetry-exporter-in-memory`; the benchmark and retention
stanzas already depend on the SDK and that exporter.

Relevant ADRs.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
requires release benchmark evidence to use isolated fixtures, fixed measured work, explicit
growth bounds and reproducible baselines with attributed causes. Read it before adding cells;
new cells must meet it.
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
defines how retention legs measure and what `Bounded` means. New legs must follow it.

Today, with a tracer configured, the instrumented paths are: the command span around each
command run, the `send` span around each published outbox batch, and the workflow span around
each workflow run. Subscription workers (process managers, routers) open no span of their own
but run commands, which do. Those are the paths to measure now, so that the later plans, which
add metadata stamping and links to them, have a baseline.


## Plan of Work

### Milestone 1: tracer-enabled benchmark cells

Add a small helper to `keiro/bench/BenchSetup.hs` that builds a recording tracer from a provider
with no processors. Confirm once that spans from it are recording
(`OpenTelemetry.Trace.Core.isRecording`); if a processor-less provider yields non-recording
spans, use the in-memory exporter's processor and record that in the Decision Log.

For each of the following, add a cell that is identical to an existing no-tracer cell except for
the tracer, following the workload-fixing rules of ADR-58:

- command path: a fixed number of commands appending one event each to distinct streams, and the
  same to one stream;
- outbox publish: `publishClaimedOutbox` draining a fixed pre-enqueued backlog with a no-op
  publish callback, at the default batch size;
- process-manager dispatch: a fixed number of events consumed through an in-memory adapter by a
  process manager that dispatches one command per event (the test suite's process-manager
  fixtures near `keiro/test/Main.hs` lines 1656–1672 show the construction).

If a no-tracer counterpart does not yet exist for one of these, add both. Name tracer cells with
a `/tracer` suffix on the existing cell name so the pairing is obvious.

### Milestone 2: tracer-enabled retention legs

Add legs to `keiro/retention/Retention/Legs.hs`, each a tracer-enabled twin of an existing leg
or a new pair where none exists: a sustained command loop; a subscription worker consuming a
long stream through the Kiroku adapter; and the outbox publisher draining a long backlog. Use
the in-memory exporter in a mode that does not accumulate spans without bound (drain or reset
it per measurement window), or a processor-less provider, so the leg measures Keiro's retention
and not the exporter's. State in each leg's comment which it uses and why.

Prove a leg can fail: temporarily make a span retain per-event data (for example add each
event's payload to a list held by a global `IORef` inside the command span body), run the
tracer command leg, record the non-`Bounded` verdict in Surprises & Discoveries, and revert
before committing.

### Milestone 3: record the baseline

Run the new cells on an otherwise idle machine following the procedure ADR-58 prescribes, and
store the results beside the existing baselines under `keiro/bench/results/` in a dated
directory with the commit hash, machine, compiler version, and exact commands. Add a short
"Tracer-enabled baselines" section to the document that already describes the benchmark
baselines (search `docs/` and `keiro/bench/` for the description of `baseline-command.csv`;
ADR-58's originating plan `docs/plans/316-run-the-benchmark-regression-guards-in-the-release-gate.md`
names it). Record, for each pair, the difference between the tracer and no-tracer cell: that
difference is the current price of tracing and the number later plans must not raise without
explanation.

If the release gate (`just release-preflight`) selects cells or legs by an explicit list, add
the new ones to it only if they are stable across three consecutive runs; otherwise leave them
out of the gate, say so, and let the parent MasterPlan's release gate decide.


## Concrete Steps

From the repository root:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal bench keiro-bench --benchmark-options="-p tracer"
nix develop -c cabal test keiro-retention --test-show-details=direct
```

To run only the new legs, set `KEIRO_RETENTION_LEGS` to their names (comma-separated, as
`Retention/Legs.hs` parses it).

Expected benchmark shape (names follow the existing cells; numbers will differ):

```text
command/append-distinct-streams:        OK
command/append-distinct-streams/tracer: OK
outbox/publish-backlog:                 OK
outbox/publish-backlog/tracer:          OK
process-manager/dispatch:               OK
process-manager/dispatch/tracer:        OK
```

Expected retention output for a new leg ends with the suite's `Bounded` verdict line.

Before committing:

```bash
nix develop -c just verify
```


## Validation and Acceptance

Each tracer cell runs and has a no-tracer twin measuring the same fixed work. Each new retention
leg ends `Bounded` on unchanged library code, and one has been shown to fail under an introduced
retention bug with the output recorded here.

Existing cells and legs are unchanged in name and result: `git diff` shows only additions under
`keiro/bench/` and `keiro/retention/`, the cabal stanza's module list if new modules were
added, and documentation. No file under `keiro/src`, `keiro-core/src` or `keiro-pgmq/src`
changes.

The recorded baseline can be reproduced by following the written procedure.


## Idempotence and Recovery

Everything is additive and repeatable. Benchmarks and legs provision fresh stores. Revert the
temporary retention bug with `git checkout -- keiro/src` and confirm `git status` shows
`keiro/src` clean before committing. If a new leg is noisy, record three consecutive readings
and the chosen bound with its rationale rather than loosening silently.


## Interfaces and Dependencies

No prerequisites. Uses `hs-opentelemetry-api`, `hs-opentelemetry-sdk` and
`hs-opentelemetry-exporter-in-memory` at the bounds already in `keiro/keiro.cabal`.

Provides to the later plans under the parent MasterPlan (331, 332, 333, 335 in `docs/plans/`):
the tracer cells and legs named above and a baseline commit. Those plans add cells and legs for
their own paths and must not rename these.
