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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-14T18:45:33Z
      verdict: "changes-requested"
      note: "Resolve EP-4/EP-6 acceptance ordering, outbox cutover replay compatibility, workflow context selection and snapshot recovery, and span-retention evidence."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-14T19:06:08Z
      mode: "update"
      note: "Apply review findings, reconcile ownership and acceptance gates, and verify available upstream releases."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-14T19:32:21Z
      mode: "implement"
      note: "Start EP-1 measurement prerequisite"
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

Span creation, context capture and decoding must be bypassed when no tracer is configured, which is how most tests and many
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
and tests, and it owns the dependency migration after the measurement baseline.

Timers and workflows (EP-6) are separate because they need a schema migration and have their
own retention concerns.

Alternatives rejected. Capturing the outbox context from the thread's current span at enqueue
was rejected: enqueue runs inside a database transaction with no access to the tracer, and a
context that differs between a first attempt and a replay would be reported as an identity
conflict, since trace headers are part of the frozen producer content digest
([ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md)).
Deriving it from the source event's metadata is deterministic under the immutable producer cutoff in ADR-59. Routing subscription workers
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
  DSL capability profiles freeze fold identity; they do not provide a producer deployment switch.
- [ADR-59](../adr/0059-durable-trace-correlation-preserves-replay-and-exact-wake-identity.md): fixed producer cutovers, exact wake selection and span-ownership acceptance
  are the accepted constraints for EP-1, EP-3 and EP-6; implementation is still pending.

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
| 1 | Establish tracing-enabled performance and retention baselines | docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md | None | None | Complete |
| 2 | Stamp trace context on appended events and name command spans by category | docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md | EP-1 | None | Complete |
| 3 | Derive outbox creation context from source events and link it from the send span | docs/plans/332-derive-outbox-creation-context-from-source-events-and-link-it-from-the-send-span.md | EP-1, EP-2 | None | Complete |
| 4 | Open linked processing spans in subscription workers and the inbox consumer helper | docs/plans/333-open-linked-processing-spans-in-subscription-workers-and-the-inbox-consumer-helper.md | EP-1, EP-2, EP-5 | None | Complete |
| 5 | Align keiro-pgmq job spans with Shibuya 0.13 and expose the correlation policy | docs/plans/334-align-keiro-pgmq-job-spans-with-shibuya-0-13-and-expose-the-correlation-policy.md | EP-1, Shibuya gate, PGMQ adapter gate | None | Complete |
| 6 | Persist trace context on timers and workflow journals and link it on fire and resume | docs/plans/335-persist-trace-context-on-timers-and-workflow-journals-and-link-it-on-fire-and-resume.md | EP-1, EP-2 | EP-4 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

EP-1 blocks EP-2, EP-3, EP-4, EP-5 and EP-6 as a whole: each compares its working tree against a
baseline that must already contain the tracer-enabled benchmark cells and retention legs.

EP-2 blocks EP-3, EP-4 and EP-6 as a whole: consumers use its helpers and extend its
correlation ADR. EP-5 owns the repository-wide dependency bump and completes before EP-4,
so there is one owner for adapter construction changes and common tracing tests.

The external release gates were verified on 2026-11-14 against Hackage package registries and
upstream tags: `shibuya-core` 0.13.0.1 (`v0.13.0.1`), `shibuya-pgmq-adapter` 0.19.0.0
(`v0.19.0.0`) and `shibuya-kiroku-adapter` 0.8.0.0
(`shibuya-kiroku-adapter-v0.8.0.0`). They are available. EP-5 adopts
`shibuya-core ^>=0.13.0.1` and the matching adapter bounds across all packages, including
DSL tests, and verifies a complete dependency solve in the Nix shell.

The upstream work is recorded in
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`,
`mori://shinzui/shibuya/plans/58-adopt-trace-correlation-in-the-pgmq-adapter`, and
`mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default`.

Execution order is EP-1, EP-2, EP-3, EP-5, EP-4, EP-6. If a new external compatibility blocker
prevents EP-5, EP-6 may instead complete after EP-3: EP-4 remains a soft dependency for EP-6,
and the combined EP-4/EP-6 check is an initiative release gate, not child acceptance.

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

1. With no tracer configured, span helpers capture no context and decode no headers. Existing
   no-tracer publisher/command cells show no allocation change. Durable producer derivation is
   deliberately tracer-independent under its explicit policy; its lookup cost is measured
   separately. EP-6 attributes additive nullable-column costs in timer reads and suspension writes.
2. With a tracer, added work per unit is a bounded constant: one context read and two metadata
   keys per appended batch of events, one link per processed message, at most 128 links on any
   span that covers a batch; at most two event lookups and one trace-hint read per traced resume.
3. Nothing reachable from a span may reference an event payload, a row, an envelope, or an
   unevaluated thunk over them. Links hold an evaluated span identity and, on batch spans, an
   evaluated message identifier.
4. Heap residency under sustained work stays within `Bounded`. Separately, the EP-1 ownership
   probe retains spans while payload weak references clear; each link-building plan extends it.
   A span-owned negative control must fail that probe. Bounded heap alone is not ownership proof.
5. Stored trace context never changes the outcome of a replay, a duplicate check, a digest, or
   an identity comparison. Where a stored context participates in a frozen digest (the producer
   outbox), it must be derived deterministically from durable data.

**The `shibuya-core` 0.13 surface.** Consumed by EP-4 and EP-5; defined in the Shibuya
MasterPlan cited above. EP-4 calls `Shibuya.Telemetry.Process.withProcessSpanIO` with the
adapter's `telemetry.traceCorrelation`; EP-5 calls the Effectful `withProcessSpan` for the bounded drain and passes an
`AdapterTelemetry` into the PGMQ adapter configuration. Both must update every test that matches
the old span name `<destination> process`.

**The dependency bump.** Raising `shibuya-core` to `^>=0.13.0.1` (and the matching
`shibuya-pgmq-adapter` and `shibuya-kiroku-adapter` bounds) touches `keiro`, `keiro-pgmq`, the
test support package and every in-memory adapter. EP-5 owns it; EP-4 consumes the accepted result.

**Replay-safe producer adoption.** EP-3 owns `IntegrationProducer.tracePolicy`, generated
construction sites, and the fixed `DeriveTraceAfter` position cutoff. Legacy producers preserve
draft trace context. Every worker uses the same durable cutoff across replays and supported
rollback; trace conflicts remain strict. See ADR-59.

**Workflow context selection.** EP-6 owns the trace-await hint lifecycle and two bounded event
lookups independent of snapshot hydration. `origin` identifies the generation's first persisted
event, not an assumed first invocation. `wake` identifies the exact previously awaited step;
unavailable evidence yields no link.

**Migrations.** Only EP-6 adds one (trace columns on `keiro.keiro_timers` and a nullable
`trace_awaited_step` hint on `keiro.keiro_workflows`). It follows
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
process manager's processing span, and that this span links to the first command's span. EP-4 accepts this command-chain test independently. After EP-4 and EP-6 are both Complete,
run the combined reaction-to-timer-to-workflow case as an initiative release gate. EP-6 tests
its timer/workflow path with directly supplied traced context and can complete before EP-4.


## Progress

EP-1 is Complete. Eight benchmark cells, five serial timing samples, native Tasty allocation
receipts, workload-count diagnostics and all 22 retention/ownership examples pass. The earlier
Mori failure was an outdated shell connection string; the corrected local connection passes
registry discovery, terminology and the complete repository verification gate. Evidence is in
`keiro/bench/results/tracing-baseline-v1/`. EP-2 is Complete with event-stamping, category span names, strict scalar ownership and
matched benchmark evidence. EP-3 is Complete with immutable producer adoption, bounded root batch links and
accepted performance/ownership evidence. EP-5 is Complete with released dependency alignment and both-path job correlation/ownership.
EP-4 is Complete: all subscription workers correlate, and the real command/event/Kiroku/
manager/command/event chain passes with metadata, links and child parenting. EP-6 is Complete:
timer and workflow creation contexts persist, exact wake/origin correlation survives snapshots,
and retained-span ownership and five matched measurement pairs satisfy the bounded-work reading rule.

All six implementation plans are Complete. Full `just verify` passes at `3bc78fab`, followed
by focused review checks at `412721f4` and a stronger distinct-row ownership probe. The approved `0.25.0.0` candidate at `0d0f87cb` passes release preflight, the full
correctness stage and native `nix flake check`. Producer identity and outbox guards pass;
inbox, command, projection and read-model historical guards fail under recorded competing
load. Attribution remains unresolved and publication is blocked. See the
[release status](../../keiro/bench/results/release-gates/0.25.0.0-release-status.md).

Cross-plan gates not owned by a child plan:

- [x] Shibuya gate: `shibuya-core` 0.13.0.1 verified on Hackage and upstream tag (2026-11-14).
- [x] Adapter gate: `shibuya-pgmq-adapter` 0.19.0.0 and `shibuya-kiroku-adapter` 0.8.0.0
  verified on Hackage and upstream tags (2026-11-14).
- [x] Combined EP-4/EP-6 check: reaction schedules a timer, firing wakes a workflow, and exact
  wake/origin links survive a workflow snapshot and an unrelated later signal.
- [ ] Keiro release with all six plans, passing the repository's release preflight including the
  benchmark gates of ADR-58 and the retention gate of ADR-48, with no unexplained change in the
  no-tracer cells.
- [x] Initiative acceptance: in the `jitsurei` example with a tracer and the local trace
  backend, one request can be followed from its command span, by links, through a process
  manager reaction, a second command, an outbox send and a workflow resume.


## Surprises & Discoveries

- EP-6's generic one-event origin read sorted/joined all 1,001 journal events before LIMIT. Indexed reference discovery alongside the trace hint, followed by normal event reads, preserves read hooks and keeps evidence retrieval independent of snapshot size. Five matched pairs show about 0.12 ms added per traced resume at both tested history sizes; ADR-59/60 retain the durable rule.
- The combined integration gate and real backend demonstration pass. The latter retains ten spans in six traces with explicit creation links across request, fulfillment processing, dispatched packing, send, timer and workflow resume. See `keiro/bench/results/tracing-timers-workflows-v1/backend-proof.json`.

- EP-2's retained-span no-op probe exposed lazy SDK attribute values retaining typed business
  payloads through outcome projections. Force scalar projections before SDK ownership; later
  link-building plans must do the same for message/row attributes. ADR-60 records the contract
  and the observed red/green ownership evidence.
- Subscription workers do not run under Shibuya's runner, so the Shibuya initiative's processing
  span and policy do not reach them. They need their own span (EP-4). Found by reading
  `ProcessManager.hs`, `Router.hs` and `ProcessManager/Reaction.hs` on 2026-11-11.
- Trace headers are inside the frozen producer content digest (`contentFields` in
  `keiro/src/Keiro/Outbox/Identity.hs`, class `TraceField`). A context captured from the current
  span would differ on replay and surface as `ProducerIdentityConflict [TraceField]`. This is
  why EP-3 derives the context from the source event instead.
- A rolling deployment can still produce that conflict: an event stamped by a new node, first
  enqueued by an old node (no context) and replayed by a new node (derived context). EP-3 uses an immutable producer cutoff, selected with producers and writers quiescent,
  so pre-cutover events remain draft-only on every replay. A deployment Boolean is insufficient.
- Inbox handlers run synchronously in the caller's thread in both inbox modes, so the inbox has
  no deferred work to link. The `traceparent` stored on inbox rows is read back only by lookup
  and listing functions. `withConsumerSpan` has no caller outside the tests.
- An outbox batch is not grouped by destination, so `send <destination>` taken from the first
  row misnames mixed batches.
- Two existing tests assert exact event metadata (`keiro/test/Main.hs` near lines 2353 and
  5570). They run without a tracer and should be unaffected; EP-2 confirms.


## Decision Log

- Decision (2026-11-15 UTC): Accept EP-6's explained constant tracing cost under the existing reading rule; keep historical release guards unchanged.
  Rationale: Five paired recordings show untraced time changes of 1.8–7.6% and bounded, measured nullable-schema allocation. Traced resumes add 0.121/0.119 ms at 1/1,000 steps (+27.85%/+13.67%). The new short-workload 25% trial is retained as refusing diagnostic evidence, not silently converted to a passing guard. This initiative requires attribution and bounded work; no historical ceiling or guard is relaxed.
- Decision (2026-11-15 UTC): Distill the completed implementation into ADR-1, ADR-59 and ADR-60.
  Rationale: Review of all six child Decision Logs and Outcomes found durable rules for shared helper ownership, immutable producer adoption, explicit tracing enablement, scalar ownership, root/link scope, exact snapshot-independent attribution and rollback. Those records now own them; execution details stay in child plans and receipts.

- Decision (2026-11-14): Run the complete repository gate for the unchanged-runtime baseline
  and again for the integrated final candidate. Between them, accept children using their
  affected builds, behavior suites, retention/ownership probes, measurements and documentation
  checks, reusing baseline evidence only for unchanged checks. A dependency or generated-code
  change requires its affected consumer suites. Hard artifact dependencies and release gates
  remain unchanged.
  Rationale: The user requested deliberate, efficient testing. Repeating unrelated DSL mutation
  proofs after every telemetry-only edit adds no distinct evidence; final integration still
  receives the complete gate. Child plans record their actual checks and reused evidence.

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


- Revision (2026-11-14): Applied review findings: fixed producer cutover and rollback semantics,
  exact snapshot-independent workflow attribution, retained-span ownership probes, a separate
  combined release gate, and EP-5 ownership of the now-available dependency releases.


## Outcomes & Retrospective

Implementation is complete across all six children, with correlated events, subscription/job
processing, outbox sends, timer fires and workflow resumes. Existing replay identities, producer
digests and snapshot formats are preserved. The full verification, targeted review checks,
recording allocation/timing measurements, retained-span probes and real backend graph are retained.
The user approved the 0.25.0.0 release on 2026-11-14. The prepared candidate passes
full correctness and native Nix checks, but four historical benchmark guards are red.
Their original evidence and competing-load observations are retained. Publication remains
blocked pending passing guards; thresholds and baselines are unchanged.
