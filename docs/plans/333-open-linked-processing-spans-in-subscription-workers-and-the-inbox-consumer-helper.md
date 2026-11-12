---
id: 333
slug: open-linked-processing-spans-in-subscription-workers-and-the-inbox-consumer-helper
title: "Open linked processing spans in subscription workers and the inbox consumer helper"
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

# Open linked processing spans in subscription workers and the inbox consumer helper

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Keiro's process managers, routers and reactions are *subscription workers*: each consumes a
stream of recorded events and reacts, usually by dispatching commands. When such a worker
handles an event today, no tracing span is opened for it. The commands it dispatches each get a
span, but those spans are unrelated to the event that caused them and to the command that wrote
that event. A flow that goes command, event, process manager, command appears in a trace backend
as disconnected fragments.

After this change, with a tracer configured, each event a subscription worker handles is wrapped
in a processing span named `process <worker name>`. That span carries a *link*, OpenTelemetry's
pointer to a causally related span in another trace, to the event's *creation context*: the
identity of the command span that appended it, which Keiro records in event metadata. Commands
the worker dispatches run inside the processing span and become its children, and the events
they append record their own command span in turn. The whole chain can then be followed.

Whether the processing span is also a child of the creation context, rather than a separate
trace, follows the policy of the Shibuya adapter the worker reads from; for the Kiroku
event-store adapter the default is a separate, linked trace, because subscriptions replay
history.

The same plan makes the exported but unused helper `withConsumerSpan` link to its message's
creation context, so applications that call it directly get the same behaviour.


## Progress

- [ ] M1: The repository builds and all tests pass against `shibuya-core` 0.13 and the matching
  adapter releases (if a sibling plan has not already done this bump).
- [ ] M2: Process managers, routers and reactions open one linked processing span per handled
  event when given a tracer, and none otherwise; dispatched commands are its children.
- [ ] M3: The end-to-end chain test passes: command, event, process manager, command, event.
- [ ] M4: `withConsumerSpan` links to the creation context.
- [ ] M5: Benchmark and retention gates pass; costs recorded.
- [ ] M6: Documents and the correlation ADR updated; parent MasterPlan updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Workers open their own processing span with Shibuya's shared span function instead
  of running under Shibuya's runner.
  Rationale: The workers deliberately drain the adapter stream themselves to control ordering,
  retries and acknowledgement. ADR-1 rejected adopting the runner merely to obtain telemetry,
  and also showed the cost of copying the span by hand. `shibuya-core` 0.13 exports the span
  construction as a function for exactly this use.
  Date: 2026-11-11

- Decision: The span's destination is the worker's name, not the stream or category.
  Rationale: It is low-cardinality and is what an operator searches for. The consumed event's
  stream and type are attributes.
  Date: 2026-11-11

- Decision: The parent-or-link policy is read from the adapter (`adapter.telemetry`), not from
  a Keiro option.
  Rationale: The Shibuya initiative makes the policy a property of the message source. A second
  Keiro-level switch would let the two disagree.
  Date: 2026-11-11

- Decision: The inbox gets no span of its own.
  Rationale: Both inbox modes run the handler synchronously on the caller's thread, inside
  whatever span the transport's processing loop opened. There is no deferred work to link.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a child of
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`.
Prerequisites:

- `docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md` Complete
  (tracer-enabled process-manager benchmark cell and subscription-worker retention leg exist).
- `docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md`
  Complete: commands run with a tracer write `traceparent`/`tracestate` into the metadata of
  appended events, and `Keiro.Telemetry` exports `traceContextFromMetadata` and
  `creationLinkFromTraceContext`.
- `shibuya-core` 0.13.0.0 on Hackage, and releases of `shibuya-kiroku-adapter` and
  `shibuya-pgmq-adapter` built against it. Verify on Hackage itself, not only the local index.
  If they are not published, this plan cannot start.

Run everything in the Nix development shell (`nix develop -c …`).

What `shibuya-core` 0.13 provides (from
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`; read
the released Haddocks and follow them if they differ from this summary, noting the difference):

```haskell
-- Shibuya.Adapter
data Adapter es msg = Adapter
  { adapterName :: !Text, source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es (), telemetry :: !AdapterTelemetry }

-- Shibuya.Telemetry.Correlation (re-exported from Shibuya.Adapter)
data TraceCorrelation = ParentAndLink | LinkOnly
data AdapterTelemetry  -- built from defaultAdapterTelemetry; field traceCorrelation

-- Shibuya.Telemetry.Process
-- Open the Consumer-kind processing span for one message: always linked to
-- the creation context in the given headers, a child of it only under
-- ParentAndLink, a root under LinkOnly. No-op without usable headers beyond
-- opening the span.
withProcessSpanIO ::
  Tracer -> TraceCorrelation -> Text -> Maybe TraceHeaders -> (Span -> IO a) -> IO a
```

The span name passed is the full name; `Shibuya.Telemetry.Semantic.processSpanName destination`
builds `process <destination>`. `TraceHeaders` is a list of header name and value byte strings;
`Envelope.traceContext :: Maybe TraceHeaders` already has that type, filled by the adapter. The
Kiroku adapter fills it from event metadata keys `traceparent`/`tracestate` and defaults its
policy to `LinkOnly`.

Where the workers are. `keiro/src/Keiro/ProcessManager.hs`, `keiro/src/Keiro/Router.hs` and
`keiro/src/Keiro/ProcessManager/Reaction.hs` each take a Shibuya `Adapter` and drain it with
`Streamly.fold Fold.drain $ Streamly.mapM handleIngested adapterSource` (process manager near
lines 906 and 1013; router near 556, 675 and 784; reaction near 371). `handleIngested` receives
an `Ingested` (envelope plus acknowledgement handle), runs the reaction synchronously, which
dispatches commands through the command entry points in `keiro/src/Keiro/Command.hs`
(`runCommandWithSql`, `runCommandWithProjections`, `runDomainCommandWithProjections`, and so
on), and then finalizes the acknowledgement. There is no fork: dispatch happens on the handler's
thread. None of these modules imports a tracer type or reads `envelope.traceContext`. The
commands they dispatch take `RunCommandOptions`, whose `tracer` field the worker's own options
already carry or contain; find how each worker's options reach `RunCommandOptions` before
adding anything.

The inbox, `keiro/src/Keiro/Inbox.hs`: `runInboxTransaction*` and `runInboxDelegated*` both run
the handler synchronously in the caller's thread. `Keiro.Telemetry.withConsumerSpan`
(`keiro/src/Keiro/Telemetry.hs` near line 361) opens a Consumer span `process <topic>` as a
child of the context in a Kafka record's headers via `withRemoteParent`; its only caller is a
test near `keiro/test/Main.hs` line 10066. It is part of the exported API.

Tests: process-manager and router tracing fixtures near `keiro/test/Main.hs` lines 1656–1672 use
an in-memory adapter; span capture uses `inMemoryListExporter`.

Relevant ADRs.
[ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) for the reasoning against
adopting Shibuya's runner and the cost of a hand-copied span.
[ADR-43](../adr/0043-delegated-inbox-intake-uses-a-downstream-event-receipt.md) (delegated
inbox intake uses a downstream event receipt rather than the inbox table) explains why the inbox
has nothing deferred.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
and
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
govern Milestone 5. Plan 331 creates the correlation ADR that this plan extends.

The contract from the parent MasterPlan: with no tracer the workers do no new work per event;
with a tracer the added work is one span and one link per event; nothing reachable from a span
references the envelope, the recorded event or its payload.


## Plan of Work

### Milestone 1: the dependency bump

If `keiro/keiro.cabal` still bounds `shibuya-core ^>=0.12.0.0`, raise it to `^>=0.13.0.0` in
every stanza and package that names it (`keiro`, `keiro-pgmq`, `keiro-test-support`, the
retention suite's `shibuya-kiroku-adapter` bound, `keiro-pgmq`'s `shibuya-pgmq-adapter` bound),
after checking the published versions. Fix every `Adapter { … }` literal the compiler reports by
adding `telemetry = defaultAdapterTelemetry`; these are in-memory adapters in tests, benchmarks
and test support. Update tests that match Shibuya's old span name `<destination> process`
(notably `keiro-pgmq/test/Main.hs`, whose `theProcessSpan` helper near line 289 matches
`jobName <> " process"`) only as far as needed to keep the suites green; the rest of the
`keiro-pgmq` alignment belongs to
`docs/plans/334-align-keiro-pgmq-job-spans-with-shibuya-0-13-and-expose-the-correlation-policy.md`.
If that plan has already done the bump, skip this milestone and say so in Progress. Record the
bump in the parent MasterPlan either way.

### Milestone 2: the processing span

Add one function to `keiro/src/Keiro/Telemetry.hs`, `withSubscriptionProcessSpan` (signature in
Interfaces and Dependencies), that is a pass-through when the tracer is `Nothing` and otherwise
calls `withProcessSpanIO` through `withRunInIO`, then sets attributes on the span:
`messaging.system = "keiro"`, `messaging.destination.name` = the worker name,
`messaging.operation.name = "process"`, `messaging.operation.type = "process"`,
`messaging.message.id` from the envelope, and any adapter-supplied `envelope.attributes` (the
Kiroku adapter contributes `kiroku.*` keys). Set the span status to error when the handler's
outcome is a failure, mirroring how the workers already classify outcomes for metrics; do not
invent new classifications.

Wrap the body of `handleIngested` in each of the three modules with it, passing the worker's
tracer, the adapter's `telemetry.traceCorrelation` read once when the worker starts, the
worker's name, and `ingested.envelope.traceContext`. The acknowledgement finalization stays
inside the span, as in Shibuya's own runner. Give each worker's options a tracer if it does not
already have one reachable; prefer reusing the tracer already carried for dispatched commands so
that an application configures one place.

Do not read the policy or build the span name per event: both are per-worker constants.

Tests, per worker kind: with a tracer and an event whose envelope carries a creation context,
one processing span named `process <worker>` with one link to that context; under an adapter
with `LinkOnly` it is a root with a new trace identifier, under `ParentAndLink` a child; the
dispatched command's span is a child of the processing span; an event without context yields a
span with no link; a duplicate or poison outcome still yields exactly one span with the
appropriate status; no tracer, no spans and no behavioural difference.

### Milestone 3: the chain

Add the representative end-to-end test named in the parent MasterPlan. Run command A with a
tracer against a real test store; consume its event through `shibuya-kiroku-adapter` with a
process manager that dispatches command B; then assert from the exported spans and stored
events: A's event metadata names A's command span; the process manager's processing span links
to A's command span; B's command span is a child of the processing span; B's event metadata
names B's command span. Assert also that with the Kiroku adapter's default policy the
processing span's trace differs from A's. Record in the parent MasterPlan that the check passed,
or what it revealed.

### Milestone 4: the inbox helper

Change `withConsumerSpan` to supply a link to the creation context found in the record's headers
in the span's creation arguments, in addition to the existing parent. Its documented behaviour
becomes "child of and linked to the upstream span". Do not add a policy parameter; an
application that wants link-only should run its consumer through a Shibuya adapter. Update the
test near line 10039 to assert the link, and state in the function's Haddock and in
`docs/user/integration-events.md` that inbox handlers are traced by the transport's processing
span and that this helper is for applications that consume Kafka records without Shibuya.

### Milestone 5: gates

Add a benchmark cell for a process manager consuming events that carry creation contexts, with
and without a tracer, and compare with a worktree of the previous plan's last commit using the
procedure plan 330 recorded. Reading rule: no-tracer cells unchanged in allocation; the tracer
cell increases by one span and one link per event, recorded per event; anything else stops the
plan. Run `keiro-retention` with its tracer subscription leg extended so events carry contexts;
it must end `Bounded`, showing the processing span does not retain envelopes.

### Milestone 6: documents

Update the capability document, the semantic-conventions audit (the "Inbox consume" and "Inbox
process" sections describe a design that was never wired; rewrite them to what now exists and
add a "Subscription workers" section), `docs/user/operations.md`, and the changelog (new spans
appear for subscription workers; the `shibuya-core` bound rises). Extend the correlation ADR
with: workers open their own span through Shibuya's function; the policy comes from the adapter;
the inbox has no span. Mark this plan Complete in the parent MasterPlan and update Progress.


## Concrete Steps

From the repository root:

```bash
cabal update
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-test --test-show-details=direct --test-options='--match "processing span"'
nix develop -c cabal test keiro-test
nix develop -c cabal test keiro-pgmq-test
nix develop -c cabal test keiro-retention
nix develop -c cabal bench keiro-bench --benchmark-options="-p process-manager"
nix develop -c just adr-validate
nix develop -c just verify
```

Expected new test lines:

```text
process manager opens one linked processing span per event
router opens one linked processing span per event
dispatched command is a child of the processing span
chain: command -> event -> process manager -> command -> event is link-followable
withConsumerSpan links to the upstream span
```


## Validation and Acceptance

With a tracer, a process manager handling an event appended by command A exports a span
`process <manager name>` with a link to A's span, and the command it dispatches is that span's
child. Before this plan there is no such span and the dispatched command is an unrelated root.

The chain test passes. Without a tracer, the exported span list is empty and every existing
worker test passes unchanged.

`keiro-test`, `keiro-pgmq-test`, `keiro-retention` and `just verify` pass against
`shibuya-core` 0.13 from Hackage. The benchmark comparison shows no allocation change in
no-tracer cells and the recorded cost in tracer cells.


## Idempotence and Recovery

Source edits and dependency bounds only; no schema change. All commands are repeatable against
throwaway stores. If the Shibuya releases are missing, do not loosen bounds or pin a source
checkout to proceed; the plan stays Not Started. The span is additive telemetry, so reverting
the change leaves no data to repair.


## Interfaces and Dependencies

Prerequisites: plans 330 and 331 Complete; `shibuya-core` 0.13.0.0 and matching adapter
releases on Hackage.

Consumes `Shibuya.Telemetry.Process.withProcessSpanIO`,
`Shibuya.Telemetry.Semantic.processSpanName`, `Shibuya.Adapter.Adapter.telemetry`,
`TraceCorrelation`.

Added to `Keiro.Telemetry`:

```haskell
withSubscriptionProcessSpan ::
  (MonadUnliftIO m, HasCallStack) =>
  Maybe Tracer ->
  TraceCorrelation ->
  -- | worker name (low-cardinality destination)
  Text ->
  Envelope msg ->
  (Maybe Span -> m a) ->
  m a
```

Changed: `withConsumerSpan` adds a link; signature unchanged.

The timer and workflow plan
(`docs/plans/335-persist-trace-context-on-timers-and-workflow-journals-and-link-it-on-fire-and-resume.md`)
benefits from this plan but does not require it.
