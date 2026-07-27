---
type: Architecture Decision Record
title: Kafka consumer fatal errors are surfaced in-band in both poll modes
description: A raised librdkafka consumer fatal is reported as Left RdKafkaRespErrFatal from every poll in both callback poll modes, via a pinned hw-kafka-client fork, while routine partition conditions never kill a consumer.
timestamp: 2026-07-27T12:00:00Z
docId: ADR-11
status: Accepted
date: 2026-07-27
---

# 11. Kafka consumer fatal errors are surfaced in-band in both poll modes

Date: 2026-07-27

Status: Accepted


## Context

librdkafka raises a *fatal error* for conditions from which a client cannot recover. For
the high-level consumer the canonical case is a **fenced** static group member: a second
consumer joins with the same `group.instance.id` and the broker fences this one. After a
fatal error librdkafka permanently halts all consumer group activity — rejoins return
immediately, subscribes are treated as unsubscribes — so the consumer is dead until it is
closed and recreated.

Our consumer stack could not observe that at any layer. Three mechanics combine:

librdkafka delivers a raised fatal to the high-level consumer **only** as a consumer error
on the consumer group queue, and explicitly not through `error_cb`
(`rd_kafka_set_fatal_error0`: *"For the high-level consumer we propagate the error as a
consumer error so it is returned from consumer_poll(), while for all other client types
(the producer) we propagate to the standard error handler (typically error_cb)"*). Nor can
it fall back to `error_cb` later: `rd_kafka_consumer_poll` dispatches with
`RD_KAFKA_Q_CB_RETURN`, under which `RD_KAFKA_OP_CONSUMER_ERR` returns
`RD_KAFKA_OP_RES_PASS` — "return as message_t to application" — *before* the branch that
would invoke the error callback.

In `hw-kafka-client`'s default `CallbackPollModeAsync`, the application drains a separate
side queue while the consumer queue is drained only by a background loop whose body was
`void $ rdKafkaConsumerPoll ...`. The fatal was therefore discarded before any Haskell
code could see it, and the application polled an empty side queue forever. The same loop
leaked every message it discarded, because the c2hs marshalling wraps the result with
`newForeignPtr_`, which attaches no finalizer.

In `CallbackPollModeSync` the fatal did arrive in-band as
`Left (KafkaResponseError RdKafkaRespErrFatal)`, but `hw-kafka-streamly`'s `isFatal`
predicate had no arm for that code and fell through to `False`, so the recommended
`skipNonFatal` filter silently discarded it.

The failure mode in both modes is the same and is the worst kind: a permanently dead
consumer that looks idle. It keeps its partitions assigned, and because librdkafka counts
any poll of a consumer-flagged queue as application progress, `max.poll.interval.ms` never
evicts it either.


## Decision

A raised consumer fatal is reported **in-band, from every poll, in both callback poll
modes**, as `Left (KafkaResponseError RdKafkaRespErrFatal)`.

Three commitments follow from that contract.

**The generic code is the contract, not the underlying cause.** Both poll modes deliver
the identical value, because `CallbackPollModeSync` already receives exactly
`RdKafkaRespErrFatal` from librdkafka. Callers never discriminate by poll mode, and a
classifier needs exactly one arm rather than an open-ended enumeration of every fatal
cause that librdkafka might add. The specific cause and librdkafka's description remain
available from `Kafka.Consumer.consumerFatalError` for logging and alerting.

**Fatal state is read from librdkafka, not recorded by our own code.** The poll functions
call `rd_kafka_fatal_error` directly rather than caching what a background loop happened to
observe. That is authoritative, immune to the race where the application polls before the
background loop dequeues the error op, identical across poll modes, and adds no shared
mutable state. It is cheap: with no fatal raised, the C implementation is a single atomic
read with an early return, taking no locks.

**The fix lives upstream, behind a fork pin.** No downstream layer can observe a signal
that is destroyed inside the binding, so an application-level workaround is impossible; the
only alternative would be a no-progress watchdog, which is a heuristic timer that misfires
on legitimately idle topics. `hw-kafka-client` is therefore pinned by commit to
`shinzui/hw-kafka-client`, which also stops the background loop leaking the messages it
consumes. The pin is by commit hash, never by branch, so resolution is reproducible, and
removing the stanza restores Hackage `hw-kafka-client` 5.3.0 exactly.

A fatal is permanent, so it is reported on every subsequent poll rather than delivered once
and forgotten.

**The converse obligation is equally binding: routine conditions must not kill a consumer.**
Making fatals loud is only half a contract; the other half is that everything librdkafka
reports in-band which is *not* a failure of the consumer must leave it running. Three
partition-scoped codes are flow control, not failure, and are swallowed —
`RdKafkaRespErrPartitionEof` (caught up with a partition, delivered on every catch-up when
`enable.partition.eof` is set), `RdKafkaRespErrAutoOffsetReset` (the position was reset, or
a reset was refused), and `RdKafkaRespErrUnknownTopicOrPart` (normal inside a
topic-creation window). A fourth, `RdKafkaRespErrNoOffset`, means a commit found nothing to
commit; hw-kafka-client's own offset-commit callback documentation states it "is not to be
considered an error", so commits treat it as success.

Throwing on these is not a cosmetic problem. Consumer interpreters close the consumer as
they unwind, so a supervised service restarts, re-subscribes, meets the same persistent
partition condition, and crash-loops — and in the partition-EOF case it does so precisely
when the consumer has succeeded at catching up.

Where a caller genuinely needs to observe a swallowed condition — a bounded read that stops
at partition EOF — the fidelity is offered through a separate operation
(`pollMessageEither` in kafka-effectful, `skipNonFatalExcept` in hw-kafka-streamly) rather
than by widening the default. The classification itself lives in one pure, testable place
per package (`Kafka.Effectful.Consumer.Classify`, `Kafka.Streamly.Stream.isFatal`) so the
two interpreters within a package cannot drift and the two packages can be diffed against
each other.

**Trace context is per-record.** In the traced interpreter, a record's extracted context is
installed only for the duration of its own span and is then detached. Extraction starts
from an *empty* context rather than the ambient thread-local one, which is what makes "no
inbound headers means a new root span" true even for a record that follows a traced record
on the same thread. Without both halves, records chain into one another: the previous
record's remote context is still installed, so an unrelated headerless message is silently
adopted into a foreign trace, and the leak outlives the poll. Kafka headers are arbitrary
bytes, so they are decoded leniently and filtered to the propagator's own declared fields
before extraction — an application payload header must never be able to cost a record its
inbound trace context.


## Consequences

Every repository that builds the consumer stack must carry the same
`source-repository-package` pin, or it silently reverts to fatal-blindness in async mode.
A pin is not inherited through a dependency edge: it governs builds of the repository that
declares it, so each repository needs its own stanza. `hw-kafka-streamly` and
`kafka-effectful` carry it; `shibuya-kafka-adapter` and `shikigami` do not yet.

Any code that classifies Kafka errors must treat `RdKafkaRespErrFatal` as fatal and must
not filter it out — `hw-kafka-streamly`'s `isFatal` and `kafka-effectful`'s
`classifyPollError` both do — and must not classify by *cause*. Enumerating specific fatal
causes regresses silently the moment librdkafka adds one; the generic code plus a
throw-by-default catch-all is the shape that fails safe.

`max.poll.interval.ms` remains unusable as a liveness watchdog in
`CallbackPollModeAsync`, and this is deliberately documented rather than fixed. librdkafka
marks the consumer group queue `RD_KAFKA_Q_F_CONSUMER` — *"Polling this queue will reset
the max.poll.interval.ms timer"* — and every consumer-poll variant runs through
`rd_kafka_app_polled`, so no choice of poll function avoids it while a background loop
polls every 100 ms. Restoring the watchdog would require polling the main queue and
forwarding the consumer queue to the application's side queue, which moves rebalance
callbacks onto the application's polling thread. That is a semantic change, out of scope
for a correctness fix, and applications that genuinely need broker-side eviction on a stuck
application must use `CallbackPollModeSync`.

The pin is the deliverable; the upstream pull request is the exit strategy. The PR is
prepared but deliberately not submitted, so the pin should be assumed long-lived.

The traced consumer span still covers only the receipt of a record, not the application's
processing of it, so it is effectively a zero-duration marker at the point of delivery.
This is a deliberate exclusion, not an oversight: covering processing requires a
handler-wrapping API, which is a telemetry design question rather than a correctness fix.

This contract is established by `docs/plans/135-surface-librdkafka-fatal-errors-through-the-consumer-stack.md`
and extended by `docs/plans/136-classify-poll-and-commit-errors-and-fix-traced-context-hygiene.md`,
both under `docs/masterplans/23-make-the-kafka-consumer-streaming-stack-surface-fatal-errors-and-close-deterministically.md`.
One sibling plan remains and this record should be revised when it lands:
`docs/plans/137-guarantee-deterministic-consumer-close-in-hw-kafka-streamly.md` adds
deterministic close, without which a stream that correctly observes a fatal may still leave
the dead consumer open — heartbeating and holding its partitions — until garbage collection
runs.
