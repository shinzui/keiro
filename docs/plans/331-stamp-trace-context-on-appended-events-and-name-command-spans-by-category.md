---
id: 331
slug: stamp-trace-context-on-appended-events-and-name-command-spans-by-category
title: "Stamp trace context on appended events and name command spans by category"
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

# Stamp trace context on appended events and name command spans by category

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

When a Keiro command appends events, nothing records which trace did it. Anything that reacts
to those events later, a process manager, a projection, an outbox publisher, a workflow, cannot
relate its own tracing span to the command that caused it. The causal chain is invisible in a
trace backend.

After this change, when a tracer is configured, every event a command appends carries the
command span's identity in its metadata as the W3C `traceparent` (and `tracestate`) strings.
This is the event's *creation context*. The Kiroku adapter for Shibuya already reads exactly
those keys into the envelope it hands to consumers, so recording them is what makes every later
link possible. Someone can see it by running a command with a tracer and reading the appended
event's metadata.

The same plan fixes the command span's name. It is currently the full stream name, such as
`order-3f2c…`, which gives every entity its own span name and defeats grouping in a trace
backend. It becomes `command <category>`, such as `command order`, with the full stream name
kept as an attribute.

With no tracer configured, nothing changes and nothing is added to the command path.


## Progress

- [ ] M1: `Keiro.Telemetry` exports `traceContextFromMetadata`, `stampTraceContext` and
  `creationLinkFromTraceContext`, with unit tests; `keiro-test` passes.
- [ ] M2: Commands run with a tracer append events whose metadata carries the command span's
  context; commands run without a tracer append byte-identical metadata to before.
- [ ] M3: Command spans are named `command <category>`.
- [ ] M4: Benchmark and retention gates pass against the baseline; the cost of stamping is
  recorded here.
- [ ] M5: A new ADR, the capability document, the semantic-conventions audit and the changelog
  are updated; the parent MasterPlan is updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The context is stored as top-level `traceparent` and `tracestate` string keys in
  the event's JSON metadata.
  Rationale: `shibuya-kiroku-adapter` projects those keys into `Envelope.traceContext` and
  `kiroku-otel` writes the same keys, so existing readers work and Keiro needs no new
  dependency.
  Date: 2026-11-11

- Decision: Stamping happens only when `RunCommandOptions.tracer` is set, and reads the context
  once per command run, not per retry attempt or per event.
  Rationale: The no-tracer path must be untouched. All events of one run share the command span,
  so one read suffices, and a context that changed between optimistic-concurrency retries would
  only add noise.
  Date: 2026-11-11

- Decision: A `traceparent` already present in caller-supplied metadata is kept.
  Rationale: An application that deliberately propagates a different context must not be
  overridden by the framework.
  Date: 2026-11-11

- Decision: The command span is named `command <category>`; the stream name stays in
  `keiro.stream.name`.
  Rationale: OpenTelemetry span names should be low-cardinality. The category is the stream
  name's prefix before the first `-`, which Kiroku already defines.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a child of
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`.
It requires `docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md` to
be complete: that plan added tracer-enabled cells to `keiro-bench` and tracer-enabled legs to
`keiro-retention`, and its last commit is this plan's baseline. If the benchmark has no cells
whose names end in `/tracer`, stop.

Run everything inside the Nix development shell (`nix develop -c …`), as `AGENTS.md` requires.

The command path is `keiro/src/Keiro/Command.hs`. `RunCommandOptions` (near line 370) has
`tracer :: Maybe Tracer` and `metadata :: Maybe Value`, an optional JSON object merged into
every appended event's metadata. Four entry points wrap a command run in `withCommandSpan`
(near lines 904, 933, 1098 and 1173), passing `resolvedStreamName eventStream targetStream` as
the span name; the retry loop and the append (`appendToStream` near line 1007, `appendToStreamTx`
near line 1202) run inside that span, so the command span is the thread's current OpenTelemetry
span while events are encoded. Encoding is pure: `encodeEvents codec md` (near line 1489) maps
`encodeForAppendWithMetadata codec md` over the events and is called again on every retry with
`options ^. #metadata`.

`keiro-core/src/Keiro/Codec.hs` has `metadataFor` (near line 204): it takes the caller's
metadata object, or an empty object, inserts the schema version key, and rejects non-object
metadata with `NonObjectCallerMetadata`. Process-manager provenance is merged into metadata the
same way by `withProvenanceMetadata` in `keiro/src/Keiro/ProcessManager/Provenance.hs`, which is
the precedent to follow.

`keiro/src/Keiro/Telemetry.hs` is the only module that imports `hs-opentelemetry-api`.
`withCommandSpan` (near line 414) opens an Internal-kind span with `inSpan'`, sets
`keiro.stream.name`, and is a pass-through when the tracer is `Nothing`.
`traceContextFromCurrentSpan` (near line 473) reads the thread's current span and encodes it as
a `TraceContext` (the record `{ traceparent :: Text, tracestate :: Maybe Text }` from
`keiro-core/src/Keiro/Integration/Event.hs`); it has no caller in the library today. The W3C
decoder used by `withRemoteParent` is `decodeSpanContext` from `hs-opentelemetry-propagator-w3c`.
A span *link* is built with `OpenTelemetry.Trace.Core.NewLink { linkContext, linkAttributes }`.

Stream names are built as `<category>-<id>` by `entityStream`/`streamNameInCategory` in
`keiro-core/src/Keiro/Stream.hs`. `EventStream` has no category field; Kiroku's
`Kiroku.Store.Types.categoryName` returns the part before the first `-`.

Does stored metadata affect correctness? It was checked on 2026-11-11 and does not: replay
digests cover encoded state and registers (`keiro/src/Keiro/ReplayAudit.hs`), deterministic
identifiers hash a seed that excludes metadata (`keiro/src/Keiro/DeterministicId.hs`),
duplicate detection checks only that an event identifier exists in the stream, and snapshots
replay typed events. Two tests assert exact metadata equality, in `keiro/test/Main.hs` near
lines 2353 and 5570; both run without a tracer.

Tests that exercise tracing are in `keiro/test/Main.hs`: the command span test near lines
2391–2410 asserts the span name equals the stream name `counter-command-otel`; helpers build a
tracer with `inMemoryListExporter`.

Relevant ADRs.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
and
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
govern the benchmark and retention evidence in Milestone 4.
[ADR-24](../adr/0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
and
[ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md)
freeze replay identity; this plan must leave identifiers and digests untouched, which the check
above indicates it does. No existing ADR covers where trace context is stored; this plan creates
one.

The contract from the parent MasterPlan: with no tracer nothing new is computed; with a tracer
the added work is one context read per command run and two metadata keys per event; nothing
stored may change a replay, duplicate check, digest or identity; nothing reachable from a span
may reference event data.


## Plan of Work

### Milestone 1: the helpers

Add to `keiro/src/Keiro/Telemetry.hs` and export the three functions given in Interfaces and
Dependencies. `traceContextFromMetadata` reads a string `traceparent` and optional string
`tracestate` from a JSON object and returns `Nothing` for anything else. `stampTraceContext`
calls `traceContextFromCurrentSpan` and, when a span is current and the metadata has no
`traceparent` key, inserts the two keys into the object (creating an object when the metadata is
`Nothing`); a non-object metadata value is returned unchanged so the existing
`NonObjectCallerMetadata` error still fires. `creationLinkFromTraceContext` decodes the stored
strings with the W3C decoder into a `NewLink` with an evaluated span context and an empty
attribute map, returning `Nothing` when the strings do not decode. Define the two key names once
and reuse the header-name constants from `Keiro.Integration.Event` (`headerTraceParent`,
`headerTraceState`) so the event and message forms cannot drift.

Add unit tests beside the existing `describe "Keiro.Telemetry"` block (near line 10318):
round-trip of stamp then read; no span current leaves metadata unchanged; a caller `traceparent`
is kept; non-object metadata is unchanged; malformed stored strings give no link.

### Milestone 2: stamp on append

In each of the four command entry points, inside the `withCommandSpan` body and before the
retry loop, when `options ^. #tracer` is `Just`, compute the stamped metadata once with
`stampTraceContext (options ^. #metadata)` and use it for every encode in that run. When the
tracer is `Nothing`, do not call it. Keep the change in one helper used by all four call sites.
Check every other place that appends domain events outside these entry points (search for
`encodeForAppendWithMetadata` and `encodeEvents`); process-manager dispatch and router dispatch
go through the command entry points and need nothing. Workflow journal appends
(`keiro/src/Keiro/Workflow/Journal.hs`) are handled by
`docs/plans/335-persist-trace-context-on-timers-and-workflow-journals-and-link-it-on-fire-and-resume.md`
and are not changed here.

Tests: a command run with a tracer appends events whose metadata `traceparent` decodes to the
trace identifier and span identifier of the exported command span; all events of one run share
it; a run that retries after a concurrency conflict still stamps once; a run without a tracer
produces metadata equal to today's (the two exact-equality tests keep passing untouched); caller
metadata with its own `traceparent` survives; a process manager dispatching a command stamps the
resulting events with that command's span.

### Milestone 3: span name

Change `withCommandSpan` to take the stream name as before but name the span
`"command " <> category`, where the category is derived with Kiroku's `categoryName`; when a
stream name has no `-`, the category is the whole name. `keiro.stream.name` is unchanged. Update
the test near line 2391 and any other test or document that matches the old name (search the
repository, including `jitsurei` and `docs/`, for the pattern).

### Milestone 4: gates

Add a benchmark cell `…/tracer` variant only if the baseline's command cells do not already
cover a command that appends several events in one run. Compare against a worktree of plan 330's
last commit using the procedure that plan recorded. Reading rule: every no-tracer cell shows no
allocation change; the command `/tracer` cells show an increase consistent with one context
read per run and two short strings per event, which you compute per command and record in
Surprises & Discoveries. A time regression beyond the gate's threshold, or allocation beyond
that explanation, stops the plan: look first for a per-retry or per-event context read, or for
metadata being rebuilt per event rather than once.

Run `cabal test keiro-retention` including the tracer legs; all must end `Bounded`. The stamped
strings are part of the event, not of the span, so the span must not hold the metadata value:
confirm the span body does not capture it in an attribute or closure that outlives the run.

### Milestone 5: documents

Create an ADR in `docs/adr/` following `agents/skills/exec-plan/ADR.md` (the bundle is
profile-governed: allocate the handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`,
add the log entry, run `just adr-validate`). Record: creation context is stored in event
metadata under these two keys; it is written only with a tracer, once per run, never overriding
the caller; it is telemetry and must never participate in replay, identity or digests; links are
Keiro's correlation across durable boundaries; command spans are named by category. Later plans
extend this ADR.

Update `docs/capabilities/opentelemetry-instrumentation.md` (keep its frontmatter valid and add
the new tests as evidence), the "Command run" section of
`docs/research/opentelemetry-semconv-audit.md`, `docs/user/operations.md` where it describes
tracing, and the changelog, where the span rename is listed as a breaking change for queries
that match span names, with the old and new forms.

In the parent MasterPlan, mark this plan Complete and update Progress.


## Concrete Steps

From the repository root:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-test --test-show-details=direct --test-options='--match "Keiro.Telemetry"'
nix develop -c cabal test keiro-test
nix develop -c cabal test keiro-retention
nix develop -c cabal bench keiro-bench --benchmark-options="-p command"
nix develop -c just adr-validate
nix develop -c just verify
```

Expected new test lines:

```text
stamps the command span context on every appended event
stamps once across optimistic-concurrency retries
leaves metadata untouched without a tracer
keeps a caller-supplied traceparent
names the command span by category
```


## Validation and Acceptance

With a tracer, reading back an event appended by a command shows metadata containing
`traceparent` whose trace and span identifiers equal the exported command span's; without a
tracer, the metadata is exactly what it was before this plan. Before this plan the first case
has no `traceparent`.

A command against stream `counter-42` produces a span named `command counter` with
`keiro.stream.name = "counter-42"`.

`keiro-test`, `keiro-retention` and `just verify` pass. The benchmark comparison shows no
allocation change in no-tracer cells, and the tracer-path cost is recorded here with its
explanation.


## Idempotence and Recovery

All changes are source edits recoverable with git, and all commands are repeatable. Events
appended during testing live in throwaway test databases. Stamping is additive to metadata and
is ignored by every reader that does not look for it, so a deployment can be rolled back without
data repair: events written with the keys remain valid for older code.


## Interfaces and Dependencies

Prerequisite: plan 330 Complete. No new package dependency.

Added to `Keiro.Telemetry`:

```haskell
traceContextFromMetadata :: Maybe Value -> Maybe TraceContext
stampTraceContext :: (MonadIO m) => Maybe Value -> m (Maybe Value)
creationLinkFromTraceContext :: TraceContext -> Maybe NewLink
```

Changed: `withCommandSpan` names its span `"command " <> category`; signature unchanged.

Consumers under the parent MasterPlan: the outbox plan (332) needs only Milestone 1; the
subscription-worker plan (333) and the timer and workflow plan (335) need this plan Complete.
