---
id: 332
slug: derive-outbox-creation-context-from-source-events-and-link-it-from-the-send-span
title: "Derive outbox creation context from source events and link it from the send span"
kind: exec-plan
created_at: 2026-11-12T04:43:48Z
intention: "intention_01m770wgzbe9vakycrq50yq7th"
master_plan: "docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md"
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
      note: "Capability activation still conflicts on replay of rows enqueued before activation; specify durable per-event cutover semantics and test activation and rollback."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-14T19:06:08Z
      mode: "update"
      note: "Apply review findings, reconcile ownership and acceptance gates, and verify available upstream releases."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-14T23:12:09Z
      mode: "implement"
      note: "Implement immutable producer trace policy and bounded root batch links"
---

# Derive outbox creation context from source events and link it from the send span

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Keiro's outbox stores integration events in the database inside the transaction that produced
them, and a background publisher sends them to Kafka later. That is the textbook case where the
work that sends a message runs after the work that created it has finished.

Today an outbox row carries trace context only if the application fills it in, which the
library never does, so in practice messages leave Keiro without it. The publisher's tracing
span, `send <destination>`, has no relation to anything: no parent and no link. For a batch it
is named and attributed from the first row, although a batch can contain several destinations.

After this change, with tracing configured: an outbox row produced from a domain event carries
that event's *creation context*, the identity of the command span that appended it, after the application adopts a fixed producer cutover policy; the Kafka headers carry it to consumers as they already would; and
the publisher's span is a root span with one *link* per row to that row's creation context. A
link is OpenTelemetry's pointer from one span to another causally related span in a different
trace. From a command's trace, a backend that follows links reaches the publish; from the
publish, it reaches every command whose event was in the batch.

A person can see it by enqueuing from two commands, running the publisher with a tracer, and
finding one `send` span with two links.


## Progress

- [x] M1 (2026-11-14): The immutable producer cutover policy and activation/rollback fixtures satisfy ADR-42
  and ADR-59; policy plumbing is explicit at every enqueue entry point.
- [x] M2 (2026-11-14): `enqueueProducerEventTx` fills a missing `traceContext` from the source event's
  metadata under that rule; replays stay identical; tests pass.
- [x] M3 (2026-11-14): The publisher's span is a root with one bounded link per row, correctly named for
  mixed-destination batches, carrying `messaging.batch.message_count`.
- [x] M4 (2026-11-14): Benchmark and retention gates pass; costs recorded.
- [x] M5 (2026-11-14): Documents and the correlation ADR updated; parent MasterPlan updated.


## Surprises & Discoveries

- The current DSL scaffolder emits mapper holes rather than `IntegrationProducer` records.
  Repository-wide source search found one filled consumer fixture, now explicitly preserving
  draft trace context; its live-runtime compile suite is the affected consumer check.
- The focused outbox suite passes 66 examples and telemetry passes 13, including root/restore,
  mixed destinations and 200 valid contexts bounded to 128 links. The actual mixed-batch
  retained-span payload probe also passes before any exported attributes are inspected.
- Kept the public `withProducerSpan` API and added a batch helper. Link attributes use the
  API's existing `AttributeMap` interface; no dependency or digest change is needed.
- The first comparison exposed allocation in bypass cases from lost enqueue specialization.
  Keeping the canonical enqueue helper inline and sharing benchmark producer configuration
  removes that regression. Retain the initial and specialized measurements; publisher rows
  are unaffected by this enqueue-only change. Explicit/pre-cutover cases pay the position
  check but perform no metadata read.


## Decision Log

- Decision (2026-11-14): Replace deployment toggles with immutable per-producer event-position cutovers and explicit rollback limits.
  Rationale: Resolve the recorded review findings before implementation; accepted durable constraints
  are recorded in [ADR-59](../adr/0059-durable-trace-correlation-preserves-replay-and-exact-wake-identity.md).

- Decision: The context is derived from the source event's metadata at enqueue, not read from
  the current span.
  Rationale: Enqueue runs inside a database transaction (`Tx.Transaction`) with no tracer and
  no I/O. More importantly, trace headers are one of the field classes in the frozen producer
  content digest; a context that differed between a first attempt and a replay would be
  reported as `ProducerIdentityConflict [TraceField]`. A value read from the stored source event
  is the same every time.
  Date: 2026-11-11

- Decision: The producer content digest and its field list are not changed.
  Rationale: ADR-42 makes them a versioned contract. Removing trace from the digest would be a
  new identity version with its own migration story; deterministic derivation makes that
  unnecessary.
  Date: 2026-11-11

- Decision: The send span takes no parent and links every row, up to 128, each link carrying
  the row's message identifier.
  Rationale: The publisher runs after the creating spans have ended, and a batch has many
  creators. The OpenTelemetry messaging conventions describe exactly this shape for batch
  publishing: links to each message's creation context, per-message attributes on the links,
  and `messaging.batch.message_count` on the span. 128 is the SDK's default link limit.
  Date: 2026-11-11

- Decision: Messages continue to carry the row's creation context, not the send span's.
  Rationale: The conventions define the creation context as what is attached to the message, so
  consumers relate to the work that created it. The send span is reachable from the same
  context by its link.
  Date: 2026-11-11


## Outcomes & Retrospective

Complete. Canonical producers now choose an explicit immutable trace policy; legacy,
cutoff boundary, restart/rollback, explicit override and GC sequences preserve strict
identity. The literal producer digest and `TraceField` conflicts remain unchanged.
The batch-aware publisher opens restored-context roots with at most 128 links and
correct uniform/mixed attributes; the single-event public helper retains its API.

Evidence is in `keiro/bench/results/trace-outbox-v1/`: matched dependency versions,
source/binary hashes, reproducible control/candidate harness patches, native allocation
CSV, initial and specialized measurements, 66 outbox examples, 13 telemetry examples,
25 retention/ownership examples, and a final 22-example identity recheck. The filled DSL
consumer and strict affected documentation/extension/re-export checks pass.

All accepted timings are −6.4% to +4.4%, within the unchanged 25% ceiling. No-tracer
publisher allocation differs by less than 0.08%; legacy enqueue allocates 0.97% less.
Pre-cutover/explicit policy comparison adds about 225 B per row, with no metadata lookup.
Eligible derivation adds about 6.7 KB per row versus candidate legacy through lookup,
normalization and SQL trace fields. Traced contextual publishing adds about 1.24 KB per
row versus the old no-link path. The distinct-context retention leg ends Bounded at
222 B/op and 0.21 MiB growth; actual mixed 200-row spans release payloads uninspected.

ADR-60 and the producer adoption guide retain the quiescent activation and policy-aware
rollback requirements. The final full repository gate remains at initiative integration;
unaffected checks reuse the accepted EP-1 baseline per the Master's validation cadence.


## Context and Orientation

This is a child of
`docs/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries.md`.
Prerequisites: `docs/plans/330-establish-tracing-enabled-performance-and-retention-baselines.md`
Complete (tracer-enabled outbox benchmark cell and retention leg exist), and
`docs/plans/331-stamp-trace-context-on-appended-events-and-name-command-spans-by-category.md`
Complete, including its correlation ADR, which provides in `Keiro.Telemetry`:

```haskell
traceContextFromMetadata :: Maybe Value -> Maybe TraceContext
creationLinkFromTraceContext :: TraceContext -> Maybe NewLink
```

If `traceContextFromMetadata` does not exist in `keiro/src/Keiro/Telemetry.hs`, stop. Plan 331
as a whole makes commands write `traceparent`/`tracestate` into the metadata of the events they
append; this plan's enqueue tests can construct such events directly, but the full prerequisite is required because this plan extends its accepted correlation ADR.

Run everything in the Nix development shell (`nix develop -c …`).

Outbox enqueue, in `keiro/src/Keiro/Outbox.hs`. An application describes an outgoing message as
an `IntegrationEventDraft` (near line 186), which has `traceContext :: Maybe TraceContext`.
`enqueueProducerEventTx producer recorded emission draft` (near line 260) is the canonical
producer path: it is given the `RecordedEvent` the message is produced from, fills the draft's
`sourceEventId` and `sourceGlobalPosition` from that event when the draft left them empty (using
`<|>`), converts the draft with the pure `draftToEvent`, and stores it with
`enqueueProducerOutboxTx`. A second, inline path, `enqueueIntegrationEventTx` (near line 127),
has no source event. Both run in hasql's `Tx.Transaction`.

Producer identity, in `keiro/src/Keiro/Outbox/Identity.hs`. `contentFields` lists the field
classes whose canonical JSON forms the producer content digest; one is
`(TraceField, headers [headerTraceParent, headerTraceState])`. `differingContentFields` compares
a replayed enqueue with the stored row and `enqueueProducerOutboxTx`
(`keiro/src/Keiro/Outbox/Schema.hs` near line 73) returns `ProducerDuplicateIdentical` or
`ProducerIdentityConflict` with the differing classes.

Publishing, in `keiro/src/Keiro/Outbox.hs` near lines 317–415.
`publishClaimedOutbox publish options metrics` claims a batch with
`claimOutboxBatch orderingPolicy batchSize` (ordered by creation time, limited by `batchSize`,
not grouped by destination), hands the whole batch to the caller's `publish` callback (singleton
batches under the `StopTheLine` policy), and wraps that in `withBatchSpan`, which calls
`Keiro.Telemetry.withProducerSpan tracer (firstRow ^. #event) (outboxRowToKafkaRecord firstRow)`
and adds `keiro.outbox.batch.size`. `withProducerSpan` (`keiro/src/Keiro/Telemetry.hs` near line
333) opens a Producer-kind span named `"send " <> destination` with `inSpan'` and default
arguments, which means no links and whatever parent the publisher thread's current context
holds. `OutboxPublishOptions` (`keiro/src/Keiro/Outbox/Types.hs` near line 171) has
`tracer :: Maybe Tracer`.

Wire headers. `outboxRowToKafkaRecord` (`keiro/src/Keiro/Outbox/Kafka.hs`) encodes
`integrationHeaders` (`keiro-core/src/Keiro/Integration/Event.hs` near line 170), which emits
`traceparent` and `tracestate` from the row's stored `traceContext`. This plan does not change
that.

Existing tests: `keiro/test/Main.hs` near line 8839 ("publishClaimedOutbox Producer span") and
8884 (a rejection is not a span error), and the producer-identity tests around the outbox
section. `keiro/bench/ProducerIdentityBench.hs` measures the identity comparison.

Relevant ADRs.
[ADR-42](../adr/0042-producer-outbox-identity-is-a-versioned-source-event-contract.md): the
producer content digest covers "identity, routing, schema, payload, occurrence, causal, trace,
attributes, and provenance classes" and is a versioned contract. Read it in full before
Milestone 1.
[ADR-18](../adr/0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md):
covers DSL capability profiles and fold identity; it is not a deployment switch available to
`enqueueProducerEventTx`. [ADR-59](../adr/0059-durable-trace-correlation-preserves-replay-and-exact-wake-identity.md) specifies the producer cutover contract.
[ADR-37](../adr/0037-outbox-publication-rejection-is-terminal-audit-truth.md): a rejected
publication is a handled outcome, not a span error; keep that.
[ADR-58](../adr/0058-benchmark-release-gates-require-isolated-fixed-workloads-and-attributed-baselines.md)
and
[ADR-48](../adr/0048-worker-retention-gates-use-post-major-live-heap-across-isolated-legs.md)
govern Milestone 4. Plan 331 creates the correlation ADR that this plan extends.

The contract from the parent MasterPlan that applies here: with no tracer the publisher does no
new work; a batch span has at most 128 links; nothing reachable from a span references a row or
payload; a stored context must never change a replay or identity outcome.


## Plan of Work

### Milestone 1: freeze the producer cutover

Follow ADR-42 and ADR-59. Add `ProducerTracePolicy = PreserveDraftTrace | DeriveTraceAfter GlobalPosition`
to `Keiro.Outbox` and a strict `tracePolicy` field on `IntegrationProducer`. Existing constructors,
examples, generated producers and fixtures explicitly use `PreserveDraftTrace`; update the DSL
scaffolder and its golden/compile fixtures as part of this milestone. The existing enqueue
signature is unchanged. This is a documented public record change.

`DeriveTraceAfter cutoff` derives only when the source `RecordedEvent.globalPosition` is strictly
greater than the immutable cutoff. Positions at or below it retain the old draft-only behavior,
even when their metadata contains trace context. Explicit draft context always wins. Use the
recorded event position, never the draft's optional overridden provenance position. The policy
is application-owned durable configuration keyed by producer source/name and store identity;
it must be identical on every worker and retained across restart, rollback and replay.

Activation requires pausing every producer worker for that identity, draining in-flight
transactions, and pausing source writers long enough to establish a committed global-position
high-water mark with no pending append that can commit below it. Persist that mark as the cutoff,
upgrade all producer workers to policy-aware code with the same value, then resume writers and
workers. No old worker may process post-cutover events. Existing installations default to the
legacy policy until this explicit adoption; a new empty store may adopt a zero cutoff before
starting writers. Do not recompute a cutoff at startup or advance it later.

A Boolean capability is insufficient: historical rows created while it was off still conflict
after it turns on. Do not weaken `TraceField` comparison or copy existing row content over a
new candidate to hide drift. Rollback after activation requires a policy-aware binary retaining
the same cutoff; a pre-policy binary must remain stopped. Pausing workers is safe, disabling the
policy after post-cutover enqueues is not.

Test pre-cutover traced events first enqueued by legacy code and replayed after activation,
events exactly at the cutoff, post-cutover events across restart and supported rollback, explicit
draft overrides, and changed explicit context still producing `ProducerIdentityConflict`.
Repeat after successful-row GC to prove derivation does not depend on an existing outbox row.

### Milestone 2: derive at enqueue

In `enqueueProducerEventTx`, extend the existing provenance defaulting so that
`traceContext` becomes `(draft ^. #traceContext) <|> traceContextFromMetadata (recorded ^. #metadata)`
only for `DeriveTraceAfter cutoff` events above the cutoff. An explicit draft value always wins. The inline path
`enqueueIntegrationEventTx` is unchanged, because it has no source event; document on it that an
application wanting trace context there must capture it before the transaction with
`traceContextFromCurrentSpan` and that a replay must supply the same value.

This path is tracer-independent by design: the value is copied from stored data, so it is the
same whether or not the enqueuing process has a tracer, which is what keeps replays identical.
The legacy policy performs no metadata lookup. The derived policy pays one position comparison
and, for eligible events without explicit context, one metadata lookup per enqueue.

Tests: a source event with `traceparent` metadata yields a row whose `traceContext` equals it and
Kafka headers that carry it; a source event without it yields no trace context, exactly as
before; an explicit draft value wins; enqueuing the same source event twice returns
`ProducerDuplicateIdentical`; the activation and supported rollback sequences from Milestone 1 remain identical; `producerContentDigest` for an event without trace context is unchanged
from before this plan (assert against a literal captured from the current code).

### Milestone 3: the send span

Replace the first-row behaviour. In `Keiro.Telemetry`, change `withProducerSpan` (or add a
batch-aware function beside it and keep the old one exported and deprecated, if removing it
would break a documented public use; search `docs/user/api-reference.md`) so that for a batch of
rows it:

- does nothing but run the body when the tracer is `Nothing`;
- collects, in one strict pass, one link per row that has a decodable creation context, using
  `creationLinkFromTraceContext` with a one-entry attribute map of `messaging.message.id`,
  stopping at 128 and counting the remainder;
- names the span `send <destination>` when every row has the same destination and `send`
  otherwise, and sets `messaging.destination.name` only in the first case; when destinations are
  mixed, adds `messaging.destination.name` to each link's attributes instead;
- opens the Producer-kind span with those links in its creation arguments, inside an empty
  OpenTelemetry context so it is a root regardless of what the publisher thread's current
  context holds, restoring the previous context afterwards;
- sets `messaging.batch.message_count` to the batch length (keeping `keiro.outbox.batch.size`
  for existing dashboards) and `keiro.outbox.links.dropped` only when the bound was exceeded.

For a singleton batch the per-message attributes that `setProducerAttributes` sets today stay on
the span. For larger batches, attributes that differ per row must not be taken from the first
row; drop them from the span, since the links carry the identifier.

The link list must be evaluated before the span is created and must hold only span identities
and identifier text, not rows.

Tests, with the in-memory exporter: two rows from two different command spans give one span, no
parent, two links whose targets are those spans and whose `messaging.message.id` values match;
rows without context give no links; a mixed-destination batch is named `send`; 200 rows with
context give 128 links and a dropped count of 72; a publisher run inside an outer span still
yields a root send span and restores the outer span; a failed publish still sets `error.type`
and error status; a rejected publish still leaves the status unset (ADR-37); no tracer, no span.

### Milestone 4: gates

Add benchmark cells for publishing a backlog whose rows all carry distinct creation contexts,
with and without a tracer, and one for enqueue with a source event that carries context. Compare
with a worktree of the previous plan's last commit using the procedure recorded by plan 330.
Reading rule: no-tracer publish cells unchanged in allocation; the tracer publish cell increases
by one link with a one-entry map per row up to 128, recorded per row; eligible derived-policy enqueue cells add one position comparison and one metadata lookup;
legacy-policy `ProducerIdentityBench` behavior and content bytes are unchanged. Measure explicit
context and pre-cutover cases separately, since they bypass metadata derivation. Anything else stops the plan.

Add a tracer-enabled retention leg for publishing a long backlog of rows with distinct contexts,
with a bounded exporter window and require `Bounded`. Extend plan 330's separate ownership
probe with the real batch-link builder, including mixed destinations and more than 128 rows;
assert payload collection while spans remain alive. Run the whole retention suite.

### Milestone 5: documents

Update the "Outbox enqueue" and "Outbox publish" sections of
`docs/research/opentelemetry-semconv-audit.md`, `docs/user/integration-events.md`,
`docs/capabilities/opentelemetry-instrumentation.md` (valid frontmatter, new evidence), and the
changelog (behaviour change: the send span's name for mixed batches and its attribute set).
Extend the correlation ADR created by plan 331 with the outbox rules: derivation from the source
event, the rollout rule, links on the send span and the bound. Document the immutable cutoff, the quiescent activation procedure and the minimum rollback
version in the producer guide. Keep ADR-42's strict conflict semantics unchanged. Mark this plan Complete in the parent
MasterPlan and update Progress.


## Concrete Steps

From the repository root:

```bash
nix develop -c cabal build all --enable-tests --enable-benchmarks
nix develop -c cabal test keiro-test --test-show-details=direct --test-options='--match "Outbox"'
nix develop -c cabal test keiro-test
nix develop -c cabal test keiro-retention
nix develop -c cabal bench keiro-bench --benchmark-options="-p outbox"
nix develop -c just adr-validate
nix develop -c just verify
```

Expected new test lines:

```text
derives the outbox trace context from the source event metadata
keeps a replayed enqueue identical
send span is a root linking each row's creation context
names a mixed-destination batch "send"
bounds batch links at 128
```


## Validation and Acceptance

With a fixed `DeriveTraceAfter` policy, enqueuing from an eligible event whose metadata has `traceparent T` stores a row with trace context `T`
and publishes a Kafka record whose `traceparent` header is `T`; replaying the enqueue reports an
identical duplicate. Before this plan the row and header are empty unless the application set
them.

Publishing two rows created by two commands yields one root `send` span with two links to those
commands' spans. Before this plan it yields a span with no links.

The digest of an event without trace context is byte-identical to before.

`keiro-test`, `keiro-retention` and `just verify` pass; the benchmark comparison shows no allocation change in no-tracer publisher cells and legacy
enqueue cells, and attributes the derived-policy lookup cost separately from tracer costs.


## Idempotence and Recovery

Source edits only; the outbox table already has trace columns. Tests use throwaway databases.
Before activation the legacy policy remains safe on both binaries. After activation retain the
same persisted cutoff on every restart and rollback; never run a pre-policy binary for that
producer. There is no safe toggle back to draft-only behavior for post-cutover source events.
Replaying pre-cutover events remains draft-only, including after outbox garbage collection.

## Interfaces and Dependencies

Prerequisites: plans 330 and 331 Complete. No new package dependency.

Uses `Keiro.Telemetry.traceContextFromMetadata` and `creationLinkFromTraceContext`;
`OpenTelemetry.Trace.Core` (`NewLink`, `SpanArguments.links`);
`OpenTelemetry.Context.ThreadLocal` (`attachContext`, `detachContext`) with
`OpenTelemetry.Context.empty`.

Changed behaviour of `Keiro.Outbox.enqueueProducerEventTx` (signature unchanged) and of the
publisher's span helper in `Keiro.Telemetry`, whose batch-aware form is:

```haskell
withProducerBatchSpan ::
  (MonadUnliftIO m, HasCallStack) =>
  Maybe Tracer -> [OutboxRow] -> (Maybe Span -> m a) -> m a
```

If `Keiro.Telemetry` cannot import `OutboxRow` without a module cycle, take a list of
`(messageId, destination, Maybe TraceContext)` triples instead and note it here.

`IntegrationProducer.tracePolicy` and `ProducerTracePolicy` are owned here, including generated
producer construction sites. New attribute key `keiro.outbox.links.dropped`. No other plan depends on this one.
