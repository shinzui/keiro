---
type: Architecture Decision Record
title: Foreground timer resume uses expiring token ownership
description: Guarded dead timer claims fence storage transitions with expiring tokens and recover directly to Dead while consumers own authorization and external effects.
timestamp: 2026-09-08T04:14:39Z
docId: ADR-39
status: Accepted
date: 2026-09-08
---

# Foreground timer resume uses expiring token ownership

## Context

A foreground consumer needs to resume deliberately parked work using its original
timer identity and reason. Inspection alone cannot reserve that work. Ordinary
ID-only completion cannot distinguish a stale worker from a newer foreground
owner. [ADR-28](0028-operator-commands-wrap-supported-library-apis-and-respect-schema-ownership.md)
places supported mutations in the schema owner and authorization in the consumer.

## Decision

`Keiro.Timer` claims one Dead row using its exact ID, mandatory owner, non-NULL
literal reason, and explicit total attempt ceiling. Each successful claim consumes
one attempt and generates an opaque UUID token outside the retried SQL transaction.
The public handle retains the original row and a claim-time deadline snapshot.
`TimerRow`, inspection, and ordinary worker callback signatures remain unchanged.

Every claim and handle mutation acquires the row lock before checking eligibility
and database `clock_timestamp()`. Separate SQL statements in the same ReadCommitted
transaction give a waiting loser a fresh view of the committed winner. An absent
lock lookup returns immediately so a concurrent insert cannot bypass the lock. Completion,
renewal, parking, and cancellation require the current unexpired token. Validated
lease seconds fit positive PostgreSQL integer seconds; no unchecked interval
conversion or caller clock governs ownership. Renewal preserves the token; its
success does not update the handle's deadline snapshot.

Recovery locks expired guarded rows in UUID order and rechecks them under those
locks. It returns them directly to Dead, preserving the original reason, identity,
payload, due time, and incremented attempt history. It never makes them Scheduled.
Every ordinary worker pass runs recovery independently of ordinary stale-claim
requeue settings, without counting re-parks as due requeues. Foreground-only hosts
must schedule recovery themselves and run it before discovery/resume.

All existing ID-only timer mutations exclude token-bearing claims, even after lease
expiry. Workflow garbage collection remains deliberate generation-owned lifecycle
deletion under [ADR-7](0007-workflow-sleep-timers-are-generation-owned-lifecycle-state.md).
A replacement claim always has a fresh token; old handles cannot mutate it.

Consumers decode the original payload, classify the reason, recheck authorization,
and establish session availability before claiming. Refused preflights consume no
attempt. Post-claim session loss or transient failure consumes the claim's attempt;
stop local work and park it without resetting history. Lost ownership requires
cancelling local work where possible and refusing to report successful completion.
Storage leases cannot stop an already-running external call. Stable work identity
and caller-owned result deduplication remain necessary for at-least-once execution.

## Consequences

Deployments must stop or drain old timer writers, apply the forward migration,
deploy all upgraded writers, and only then enable resume. Additive nullable columns
do not make mixed old/new timer writers safe: old binaries lack token exclusions.
Rollback first disables resume and drains or recovers every guarded claim before
an older writer starts. The migration manifest, checksum lock, and native live
schema remain independent gates under
[ADR-9](0009-keiro-owns-live-schema-verification-under-pg-migrate.md).

An ambiguous claim response does not prove ownership. Inspect/recover rather than
executing optimistically. Attempt ceilings remain caller policy; raising one is an
explicit policy decision and never an automatic history reset.

## References

[ExecPlan 272](../plans/272-support-atomic-guarded-dead-timer-resume.md) records the
implementation and PostgreSQL/consumer acceptance evidence.
