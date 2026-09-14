---
type: Architecture Decision Record
title: Process-manager reactions use accepted witnesses and target-keyed recovery
description: Additive reactions separate saga-and-timer acceptance from target dispatch, recover through exact witnesses, and give target commands a new stable identity family.
timestamp: 2026-09-14T20:20:17Z
docId: ADR-41
status: Accepted
date: 2026-09-14
originatingPlan: docs/plans/279-harden-process-manager-reaction-apis-before-dsl-generation.md
---

# Process-manager reactions use accepted witnesses and target-keyed recovery

## Context

The legacy process manager always supplies a saga command, gives target
commands positional identities, and returns a shape that cannot distinguish a
typed rejection or no-op from acceptance. A generated reaction language needs
optional advancement, acceptance-dependent follow-ups, transactional schedule
and cancel operations, and honest recovery after the saga transaction commits
but target fan-out remains incomplete. Those requirements must be useful and
proved in handwritten Haskell before generated code depends on them.

Kiroku exposes an exact event-existence probe and paged forward stream reads,
but no read-by-id API. The manager's deterministic id is assigned only to the
first event of an accepted batch. It can therefore witness that acceptance
occurred, but it cannot recover the original batch boundary or reconstruct
event values for an acceptance callback. Silent decisions append no event and
leave no equivalent receipt.

Saga state, timers, and arbitrary target aggregates also cannot share one
database transaction. Recovery must preserve that boundary rather than imply
cross-stream atomicity. The public API must coexist with existing applications
without changing the legacy runner or its frozen positional identities.

## Decision

`Keiro.ProcessManager.Reaction` is an additive module beside the unchanged
legacy API. A pure `ReactionPlan` is either `NoAdvance followUps` or
`AdvanceReaction command followUps onAccepted`. Both follow-up lists are fixed
from immutable decoded input. `onAccepted` cannot inspect emitted saga events;
it is enabled only by a non-empty accepted append or by recovery of the exact
first-event witness in the intended saga stream.

An advancing reaction appends saga events and executes its timer subsequence in
one transaction. Timer operations retain their order within that transaction.
Target commands run afterwards in declared attempt order, one transaction per
command. A later failure cannot roll back an earlier append, and replay or
concurrent delivery may cause commit order to differ from attempt order.
Applications that require globally ordered target commits need a different
coordination policy.

Accepted redelivery probes all legacy-compatible manager ids, locates the exact
witness by paging only the intended stream, decodes that event, skips timer SQL,
and retries target fan-out. Recovery captures a finite stream-version ceiling
and reads pages of 256 events, so a missing witness terminates even while newer
events are appended. Missing and undecodable witnesses are explicit integrity
errors, not invented duplicate successes.

Reaction target commands use a distinct UUIDv5 identity family. Every field is
length-prefixed UTF-8: `keiro`, `process-reaction`, manager name, correlation
id, canonical source event UUID, physical target stream name, and decimal
zero-based occurrence among commands to that target. The frozen ASCII vector
is `5a89007a-a634-58bf-8002-5ea7843155f2`; the Unicode vector is
`ca7f7bd8-2b54-508f-a542-1e24da394d95`. Occurrences are counted with a strict
target-keyed map while traversing the declared list once. Reaction inputs,
target order, command meaning, and payloads must remain stable for a source
event.

After an unmatched, exhausted-conflict, or eventless target result, the runner
rechecks the intended target id in that target stream. An exact witness wins a
race and becomes `PMCommandDuplicate`; otherwise the original outcome is
preserved. A target eventless acceptance, rejection, or no-op has no durable
target receipt and may be evaluated again. A collision in another stream never
counts as success.

`NoAdvance` performs no saga read or command and runs unconditional timer
effects in their own transaction. A typed rejection, no-op, or eventless
acceptance is also silent. These outcomes have no persisted saga receipt, so
their unconditional effects may repeat on redelivery. A concurrent accepted
delivery may commit between the silent path's final witness probe and timer
transaction. Effects that must belong exclusively to durable acceptance go in
`onAccepted`; no exactly-once evaluation claim is made.

Timer scheduling keeps the existing lifecycle. `Once` is insert-only while any
row with the id exists. `Rearm` changes deadline and payload only while the row
is Scheduled. Neither revives Firing, Fired, Cancelled, Dead, or
foreground-owned rows. `cancelTimerTx` exposes the existing guarded
cancellation inside the saga transaction. An absent cancellation creates no
tombstone, terminal rows remain terminal, foreground ownership remains fenced,
and cancellation cannot revoke a callback that already claimed the timer.
Targets must make late firing benign.

The once and worker entry points share one private reducer-parameterized
engine. The once runner returns detailed saga, timer, and target results. The
worker reduces saga results before fan-out and retains only strict duplicate
counts and failure records, then uses the established process-manager poison,
retry, rejection, dead-letter, acknowledgement, and telemetry policies.
Manager failures use dispatch position -1; target failures use their overall
declared dispatch position. Witness failures halt with bounded reason codes,
and asynchronous cancellation escapes.

Adoption is an identity migration, never an automatic switch. Before an
existing manager name moves to the reaction runner, operators drain source
deliveries, incomplete fan-out, pending timers, and all permitted historical
replays. Otherwise a retained legacy saga witness can enable dispatch under a
new target id and duplicate the logical action. The same review applies to
same-target command reordering or payload changes. Version labels do not enter
the seed, and there is no automatic positional-id or router-id fallback.

## Consequences

Handwritten applications and future generators can express optional
advancement and acceptance-only effects without a parallel saga evaluator or a
new receipt table. Saga/timer rollback, partial target recovery, and worker
failure policy have one shared implementation. Existing process managers keep
their source and replay behavior.

The result types expose distinctions callers must handle: not advanced, the
original typed decision, recovered acceptance, command failure, and witness
integrity failure. Detailed one-shot results retain successful payloads, while
worker memory is bounded by the supplied follow-ups, distinct targets, and
failures rather than all successful results.

The design deliberately does not provide exactly-once silent evaluation,
cross-stream atomicity, reconstructed accepted batches, strict commit order, a
new timer generation, or dual-family migration. These are visible application
and deployment responsibilities rather than hidden compatibility behavior.

## References

[ExecPlan 279](../plans/279-harden-process-manager-reaction-apis-before-dsl-generation.md)
records the API implementation, PostgreSQL concurrency and recovery evidence,
frozen identity vectors, handwritten consumer, and validation transcript.

[ExecPlan 273](../plans/273-make-process-manager-reactions-first-class-in-keiro-dsl.md)
consumes this runtime contract as a prerequisite for generated reactions.

[ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md)
defines the UTF-8 deterministic-id rule. [ADR-29](0029-typed-domain-decisions-are-successful-additive-command-outcomes.md)
defines typed silent outcomes. [ADR-39](0039-foreground-timer-resume-uses-expiring-token-ownership.md)
defines foreground timer ownership and late-effect limits.
