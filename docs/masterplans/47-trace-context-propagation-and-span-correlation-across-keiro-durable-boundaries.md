---
id: 47
slug: trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries
title: "Trace context propagation and span correlation across Keiro durable boundaries"
kind: master-plan
created_at: 2026-11-12T04:43:48Z
intention: "intention_01m770wgzbe9vakycrq50yq7th"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T04:43:48Z
---

# Trace context propagation and span correlation across Keiro durable boundaries

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Keiro is an event-sourcing framework and workflow engine. A unit of work routinely crosses
durable boundaries: a command appends events; a process manager or router reacts to those
events later and dispatches further commands; an outbox publisher sends integration events to
Kafka after the transaction that enqueued them; a timer fires, or a workflow resumes, minutes or
days after it was scheduled; a PGMQ job runs after a delay or a retry. At each boundary the work
that continues is caused by work that has already finished.

OpenTelemetry has two ways to relate spans. A *parent* puts the later span in the earlier
span's trace. A *link* records the earlier span's identity on the later span without joining its
trace. The OpenTelemetry messaging conventions say a span that processes a message SHOULD link
to the message's *creation context* (the span identity recorded when the message was created),
that making the creation context the parent is optional and not recommended by default, and
that a span covering a batch can only use links.

Today Keiro does neither across most of its boundaries, because the creation context is never
recorded. Read from the source on 2026-11-11:

- Events appended by a command carry no trace context. `metadataFor` in
  `keiro-core/src/Keiro/Codec.hs` stamps only the schema version.
- Process managers, routers and reactions consume a Shibuya adapter's stream directly
  (`Streamly.mapM handleIngested adapterSource` in `keiro/src/Keiro/ProcessManager.hs`,
  `Router.hs` and `ProcessManager/Reaction.hs`). They do not use Shibuya's runner, so no
  processing span is opened for a consumed event, and `Envelope.traceContext` is never read.
- An outbox row's `traceContext` is set only if the application fills it; the library never
  does. The publisher's `send <destination>` span has no parent and no link, and for a batch it
  is named and attributed from the first row although a batch can mix destinations.
- Timers and workflow journal events store no trace context; each workflow resume is a new,
  unrelated span; the timer path opens no span.
- `keiro-pgmq`'s bounded drain copies Shibuya's processing span by hand
  (`withOneShotProcessSpan` in `keiro-pgmq/src/Keiro/PGMQ/Job.hs`), and jobs have no way to
  choose parent or link.
- A command span is named after the full stream name (`<category>-<id>`), which gives every
  entity its own span name.

After this initiative, with a tracer configured:

- Every event Keiro appends carries the trace context of the command span that appended it.
- Every span Keiro opens for work that continues across a durable boundary links to the
  creation context of what it continues: subscription workers per consumed event, the outbox
  publisher per row in the batch, the timer worker per fired timer, a workflow resume to the
  step that woke it, a PGMQ job per delivery.
- The causal chain command, event, reaction, command, event can be followed link by link in a
  trace backend, across any delay.
- Where one message is processed on its own, whether the span is also a child of the creation
  context follows the policy of the Shibuya adapter in use, as defined by `shibuya-core` 0.13.
- Command spans have one name per category.

None of this may cost anything when no tracer is configured, which is how most tests and many
deployments run, and it may not make a span keep message data alive. Keiro has benchmark and
heap-retention release gates; this initiative extends them to tracer-enabled runs before
changing behaviour and holds every change to them.

Excluded: correlation and causation identifiers (requested separately in
[IR-52](../improvement-requests/thread-inbound-correlation-and-causation-ids-through-events-and-dispatched-commands.md),
which is complementary: identifiers answer "which business flow", trace context answers "which
execution"); the dead-letter-before-handler gap in
[BUG-7](../bug-reports/7-pre-handler-dead-letter-has-no-process-span.md); per-step child spans
for hydration, snapshots, projections and rebuilds; baggage; extraction through a configured
non-W3C propagator on the consumer side (a `shibuya-core` limitation); metrics; and any exporter
or collector.


## Decomposition Strategy

Six child plans, split by the boundary they instrument.

Measurement is first and separate (EP-1). `keiro-bench` and the `keiro-retention` suite never
run with a tracer today, so there is no baseline for the tracer-enabled path. The later plans
compare against a commit that has the tracer-enabled benchmarks and retention legs but none of
the behaviour changes.

Stamping events (EP-2) is the foundation: nothing downstream can link until the creation
context exists on the event. It owns the metadata keys and the helpers that read and write
them. Command span naming is in the same plan because it edits the same function
(`withCommandSpan`) and is measured by the same command-path gate.

The outbox (EP-3) is one plan covering both ends, because the context written at enqueue is only
meaningful with the send span that links to it, and both are constrained by the same decision
record on producer identity.

Consumer-side spans (EP-4) cover the subscription workers and the unused inbox helper. This is
the plan that closes the causal chain, and the only one that needs a new function from
`shibuya-core`.

`keiro-pgmq` (EP-5) is separate because it is a different package with its own decision record
and tests, and it is blocked on two external releases rather than on Keiro work.

Timers and workflows (EP-6) are separate because they need a schema migration and have their
own retention concerns.

Alternatives rejected. Capturing the outbox context from the thread's current span at enqueue
was rejected: enqueue runs inside a database transaction with no access to the tracer, and a
context that differs between a first attempt and a replay would be reported as an identity
conflict, since trace headers are part of the frozen producer content digest
([ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md)).
Deriving it from the source event's metadata is deterministic. Routing subscription workers
through Shibuya's runner to obtain its span was rejected for the reason
[ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md) gives for the bounded
drain: it would change delivery semantics to obtain telemetry. A single ExecPlan was rejected
because the work spans three packages, a migration, and two external release dependencies.

Relevant ADRs, read for this plan:

- [ADR-1](../adr/0001-keiro-pgmq-job-processing-telemetry-contract.md): both `keiro-pgmq`
  execution paths emit one processing span per delivery under a shared contract, with the
  bounded path copying Shibuya's span by hand and guarded only by tests. EP-5 replaces the copy
  with a shared function and revises this ADR.
- [ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md): the
  producer content digest covers a fixed ordered list of field classes including trace, and is a
  versioned contract. EP-3 must not change the digest's inputs and must keep replays identical.
- [ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
  and
  [ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md):
  how benchmark and heap-retention evidence must be produced. EP-1 follows both.
- [ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md):
  released runtime behaviour is selected by explicit capabilities. EP-3 uses it to decide how
  the new derivation is rolled out.

The Shibuya side of this work is
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`, which
defines the link, the `TraceCorrelation` policy, the renamed processing span and the shared
span function this initiative consumes.

A new ADR is expected from EP-2 recording where creation context is stored, that links are the
correlation across Keiro's durable boundaries, and the no-tracer and retention rules. EP-5
revises ADR-1.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Establish tracing-enabled performance and retention baselines | docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md | None | None | Not Started |
| 2 | Stamp trace context on appended events and name command spans by category | docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md | EP-1 | None | Not Started |
| 3 | Derive outbox creation context from source events and link it from the send span | docs/plans/332-derive-outbox-creation-context-from-source-events-and-link-it-from-the-send-span.md | EP-1, EP-2 M1 | EP-2 | Not Started |
| 4 | Open linked processing spans in subscription workers and the inbox consumer helper | docs/plans/333-open-linked-processing-spans-in-subscription-workers-and-the-inbox-consumer-helper.md | EP-1, EP-2, Shibuya gate | None | Not Started |
| 5 | Align keiro-pgmq job spans with Shibuya 0.13 and expose the correlation policy | docs/plans/334-align-keiro-pgmq-job-spans-with-shibuya-0-13-and-expose-the-correlation-policy.md | Shibuya gate, PGMQ adapter gate | EP-1 | Not Started |
| 6 | Persist trace context on timers and workflow journals and link it on fire and resume | docs/plans/335-persist-trace-context-on-timers-and-workflow-journals-and-link-it-on-fire-and-resume.md | EP-1, EP-2 | EP-4 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

EP-1 blocks EP-2, EP-3, EP-4 and EP-6 as a whole: each compares its working tree against a
baseline that must already contain the tracer-enabled benchmark cells and retention legs.

EP-2 blocks EP-4 and EP-6 as a whole, because both read the context EP-2 writes and their tests
depend on stamped events. EP-3 needs only EP-2's first milestone, whose accepted output is the
metadata keys and the functions `traceContextFromMetadata` and `stampTraceContext` in
`Keiro.Telemetry` with `keiro-test` passing; EP-3 does not need the command span rename.

Two gates are outside this repository.

The Shibuya gate: `shibuya-core` 0.13.0.0 published on Hackage. It provides the
`TraceCorrelation` policy, the `AdapterTelemetry` record on `Adapter`, the link helper, the
processing span named `process <destination>`, and the shared span function `withProcessSpan`.
It is produced by `mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`.
Keiro's bound is `shibuya-core ^>=0.12.0.0`, so EP-4 and EP-5 cannot build until it is raised.
Raising it is itself a breaking change for Keiro's in-memory adapters and tests, which construct
`Adapter` records; whichever of EP-4 and EP-5 starts first performs the bump for the whole
repository and records it here.

The PGMQ adapter gate: a `shibuya-pgmq-adapter` release built against `shibuya-core` 0.13 with
the `telemetry` field on `PgmqAdapterConfig`, produced by
`mori://shinzui/shibuya/plans/58-adopt-trace-correlation-in-the-pgmq-adapter`. EP-5 needs it.
The retention suite uses `shibuya-kiroku-adapter`, so the matching Kiroku adapter release
(`mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default`)
is needed by whichever plan performs the bump.

Until those gates pass, EP-1, EP-2, EP-3 and EP-6 can proceed in that order; none of them needs
Shibuya 0.13. EP-6 lists EP-4 as a soft dependency only because a timer fired from inside a
subscription worker gets a better creation context once EP-4 exists.

EP-2, EP-3, EP-4 and EP-6 all touch `Keiro.Telemetry` and the same benchmark and retention
suites. Run them one at a time, each taking its baseline at the previous plan's last commit, so
every gate measures one change.

One Keiro release carries everything, after all six are Complete. A related plan in another
repository, `mori://shinzui/pgmq-hs/plans/32-link-receive-spans-to-message-creation-contexts-in-the-traced-interpreter`,
improves the `receive` spans of the traced PGMQ interpreter that `keiro-pgmq` runs on; it is
independent and blocks nothing here.


## Integration Points

**Where creation context lives on an event.** Defined by EP-2, read by EP-3, EP-4 and EP-6.
The context is two string keys, `traceparent` and optional `tracestate`, at the top level of the
event's JSON metadata, in W3C Trace Context format. These are the keys
`shibuya-kiroku-adapter` already reads into `Envelope.traceContext` and `kiroku-otel` already
writes, so no adapter change is needed. EP-2 provides, in `Keiro.Telemetry`:

```haskell
-- | Read the creation context recorded in an event's metadata.
traceContextFromMetadata :: Maybe Value -> Maybe TraceContext

-- | Add the current span's context to caller metadata, unless the caller
-- already set a traceparent. Returns its argument unchanged when no span
-- is current.
stampTraceContext :: (MonadIO m) => Maybe Value -> m (Maybe Value)

-- | Decode a stored context into a link for a new span.
creationLinkFromTraceContext :: TraceContext -> Maybe NewLink
```

Later plans must use these and must not parse the keys themselves.

**`Keiro.Telemetry` span helpers.** EP-2 changes `withCommandSpan`; EP-3 changes
`withProducerSpan`; EP-4 changes `withConsumerSpan` and adds the subscription span helper; EP-6
changes `withWorkflowSpan` and adds a timer span helper. Each plan owns only its helper. All
keep the existing rule that a `Nothing` tracer makes the helper a pass-through that does no
other work.

**The no-tracer, cost and retention contract.** Defined by EP-1 as executable gates; every
later plan must pass them and extend them to its new path.

1. With no tracer configured, nothing new is allocated or computed: no context is read, no
   metadata is modified, no header is decoded. Existing benchmark cells show no allocation
   change.
2. With a tracer, added work per unit is a bounded constant: one context read and two metadata
   keys per appended batch of events, one link per processed message, at most 128 links on any
   span that covers a batch.
3. Nothing reachable from a span may reference an event payload, a row, an envelope, or an
   unevaluated thunk over them. Links hold an evaluated span identity and, on batch spans, an
   evaluated message identifier.
4. Heap residency under sustained work stays within the retention suite's `Bounded` verdict
   with a tracer configured.
5. Stored trace context never changes the outcome of a replay, a duplicate check, a digest, or
   an identity comparison. Where a stored context participates in a frozen digest (the producer
   outbox), it must be derived deterministically from durable data.

**The `shibuya-core` 0.13 surface.** Consumed by EP-4 and EP-5; defined in the Shibuya
MasterPlan cited above. EP-4 calls `Shibuya.Telemetry.Process.withProcessSpanIO` with the
adapter's `telemetry.traceCorrelation`; EP-5 calls it for the bounded drain and passes an
`AdapterTelemetry` into the PGMQ adapter configuration. Both must update every test that matches
the old span name `<destination> process`.

**The dependency bump.** Raising `shibuya-core` to `^>=0.13.0.0` (and the matching
`shibuya-pgmq-adapter` and `shibuya-kiroku-adapter` bounds) touches `keiro`, `keiro-pgmq`, the
test support package and every in-memory adapter. One plan does it, as described in the
Dependency Graph.

**Migrations.** Only EP-6 adds one (trace columns on `keiro.keiro_timers`). It follows
`keiro-migrations/README.md`: a new forward migration through `keiro-migrate new`, never an edit
to a shipped one, and a regenerated expected-schema snapshot.

**Documents.** `docs/capabilities/opentelemetry-instrumentation.md`,
`docs/research/opentelemetry-semconv-audit.md`, `docs/user/operations.md` and
`docs/user/integration-events.md` are edited by several plans; each plan edits only the sections
for its boundary. The new ADR is created by EP-2 and extended by EP-3, EP-4 and EP-6.

**Representative end-to-end check.** The uncertain shared behaviour is the full chain: a
command's event, consumed by a process manager through the Kiroku adapter, dispatching a second
command whose event is stamped again. EP-4 owns a test that asserts, with an in-memory span
exporter, that the second command's event metadata carries a context whose trace contains the
process manager's processing span, and that this span links to the first command's span. Run
it before finalising EP-6, whose links rest on the same mechanism.


## Progress

No child plan has started. EP-1 can begin now. EP-4 and EP-5 are blocked on the Shibuya gate;
EP-5 also on the PGMQ adapter gate.

Cross-plan gates not owned by a child plan:

- [ ] Shibuya gate: `shibuya-core` 0.13.0.0 on Hackage.
- [ ] PGMQ adapter gate: `shibuya-pgmq-adapter` and `shibuya-kiroku-adapter` releases built
  against `shibuya-core` 0.13 on Hackage.
- [ ] Keiro release with all six plans, passing the repository's release preflight including the
  benchmark gates of ADR-58 and the retention gate of ADR-48, with no unexplained change in the
  no-tracer cells.
- [ ] Initiative acceptance: in the `jitsurei` example with a tracer and the local trace
  backend, one request can be followed from its command span, by links, through a process
  manager reaction, a second command, an outbox send and a workflow resume.


## Surprises & Discoveries

- Subscription workers do not run under Shibuya's runner, so the Shibuya initiative's processing
  span and policy do not reach them. They need their own span (EP-4). Found by reading
  `ProcessManager.hs`, `Router.hs` and `ProcessManager/Reaction.hs` on 2026-11-11.
- Trace headers are inside the frozen producer content digest (`contentFields` in
  `keiro/src/Keiro/Outbox/Identity.hs`, class `TraceField`). A context captured from the current
  span would differ on replay and surface as `ProducerIdentityConflict [TraceField]`. This is
  why EP-3 derives the context from the source event instead.
- A rolling deployment can still produce that conflict: an event stamped by a new node, first
  enqueued by an old node (no context) and replayed by a new node (derived context). EP-3 must
  gate the derivation so it cannot differ between nodes of one deployment.
- Inbox handlers run synchronously in the caller's thread in both inbox modes, so the inbox has
  no deferred work to link. The `traceparent` stored on inbox rows is read back only by lookup
  and listing functions. `withConsumerSpan` has no caller outside the tests.
- An outbox batch is not grouped by destination, so `send <destination>` taken from the first
  row misnames mixed batches.
- Two existing tests assert exact event metadata (`keiro/test/Main.hs` near lines 2353 and
  5570). They run without a tracer and should be unaffected; EP-2 confirms.


## Decision Log

- Decision: Creation context is stored in event metadata under `traceparent` and `tracestate`.
  Rationale: The Kiroku adapter already projects exactly these keys into the envelope and
  `kiroku-otel` writes them, so every existing reader works unchanged and Keiro adds no
  dependency.
  Date: 2026-11-11

- Decision: Links are the correlation across Keiro's durable boundaries. Parenthood is used only
  where a single message is processed through a Shibuya adapter whose policy asks for it.
  Rationale: The later work runs after the earlier span has ended, sometimes by days, and often
  fans out or batches. This is also the messaging conventions' default.
  Date: 2026-11-11

- Decision: The outbox creation context is derived from the source event's metadata, not from
  the current span.
  Rationale: Enqueue runs in a transaction without a tracer, and ADR-42 puts trace headers in a
  frozen digest that must be identical on replay.
  Date: 2026-11-11

- Decision: Subscription workers open their own processing span using a function shared with
  Shibuya, rather than adopting Shibuya's runner.
  Rationale: Same reasoning as ADR-1: do not change delivery semantics to obtain telemetry, and
  do not copy the span by hand again.
  Date: 2026-11-11

- Decision: Tracer-enabled baselines are a separate first plan.
  Rationale: The requirement is no performance regression and no space leak, and neither the
  benchmarks nor the retention suite currently runs with a tracer.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)
