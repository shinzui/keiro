---
id: 207
slug: add-the-messaging-and-read-side-command-domains-to-keiro-ops
title: "Add the messaging and read-side command domains to keiro-ops"
kind: exec-plan
created_at: 2026-08-06T03:02:06Z
intention: "intention_01kzagac32ehp93amx1sfar2ab"
master_plan: "docs/masterplans/31-build-the-keiro-ops-operational-cli.md"
---

# Add the messaging and read-side command domains to keiro-ops

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`docs/plans/206-create-the-keiro-ops-package-with-the-workflow-and-timer-command-domains.md`
creates the `keiro-ops` console with two domains and freezes its conventions
(handler functions over `OpsEnv`, human tables plus `--json`, preview-then-`--force`
mutations, schema handshake, mutations wrap supported library APIs only). This plan
completes the database-only surface: after it, an operator can triage the
transactional outbox and its dispatch dead letters, the inbox, pgmq dead-letter
queues, projection/subscription positions, sharded-subscription ownership,
snapshots, and kiroku streams — the rest of the runbook in
`docs/user/operations.md` — from the same binary with the same rails.


## Progress

- [x] Outbox + dispatch dead-letter domain.
- [x] Inbox domain.
- [x] pgmq DLQ domain.
- [x] Projection-position domain.
- [x] Shard-ownership domain.
- [x] Snapshot domain (including the truncation preflight).
- [x] Stream (kiroku) domain.
- [x] `cabal test keiro-ops-test` green with per-domain coverage.


## Surprises & Discoveries

- 2026-08-08: Exact previews and generic inspection needed narrow public APIs
  that the initial inventory did not contain. The implementation added
  read-only stale/retention candidate lists to the owning outbox and inbox
  modules, generic snapshot lookup/delete, subscription-scoped shard reads, and
  projection-scoped dedup count/prune operations. The CLI still contains no
  domain SQL. `keiro-pgmq` gained only a numeric-id convenience wrapper around
  its existing archive operation so `keiro-ops` does not need a dependency on
  the lower PGMQ implementation package.
- 2026-08-08: `subscriptionStates` in
  `mori://shinzui/kiroku/packages/kiroku-store` is explicitly live,
  process-local state, not a durable checkpoint inventory. A standalone
  `keiro-ops` process therefore normally reports no subscriptions. The command
  says this in its help and output instead of claiming durable state; a durable
  checkpoint-list command requires a future public Kiroku API and was not
  approximated with table access.
- 2026-08-08: The standalone binary cannot infer an application's current
  aggregate snapshot codec tuple. Workflow streams have Keiro's fixed public
  sentinel and are recognized by their `wf:` prefix; other streams must supply
  all three discriminator flags. Truncation remains fail-closed unless the
  evidence covers the boundary and matches those expected values, or the
  operator explicitly supplies `--skip-preflight`.
- 2026-08-08: The existing projection dedup retention contract is timestamp
  based, not global-position based, and its original mutation was global across
  projections. The shipped command accepts an ISO-8601 UTC cutoff and uses the
  new projection-scoped API, preventing one projection's maintenance pass from
  shortening another projection's redelivery window.
- 2026-08-08: PGMQ's supported `readDlq` operation claims visibility, so mutation
  previews use non-mutating queue metrics and report an honest upper bound rather
  than reading identities. The standalone binary also has no application job
  codec; it uses `aesonJobCodec @Value` to preserve and display raw JSON inside
  the versioned DLQ wrapper. Human-mode purge adds a typed queue-name
  confirmation; `--json --force` remains non-interactive.
- 2026-08-08: The supported outbox and inbox list functions are source-scoped,
  and dispatch dead-letter listing is dispatcher-scoped. Their CLI flags are
  therefore required rather than pretending that an unsupported global listing
  exists. Inbox GC correctly removes completed rows only; a poison row explicitly
  marked failed remains available for diagnosis.


## Decision Log

- Decision: The stream domain's destructive commands (`hard-delete`,
  `truncate-before set`) additionally require typing the stream name into a
  confirmation prompt when run without `--json`, on top of `--force`.
  Rationale: These are the only commands in the console that can hide or destroy
  event history; the runbook (`docs/user/operations.md` §Stream Truncation)
  prescribes a snapshot-coverage preflight precisely because mistakes here are
  visible to every consumer. Scripted (`--json`) use keeps plain `--force`
  semantics.
  Date: 2026-08-06

- Decision: Add missing preview/inspection primitives to each owning Keiro
  module, and add a small convenience wrapper to `keiro-pgmq`, rather than
  weakening preview accuracy or querying owned tables from the CLI.
  Rationale: ADR 28 makes the ownership boundary part of the operator contract;
  read-only previews are reusable library capabilities, not a reason for an SQL
  exception.
  Date: 2026-08-08

- Decision: Expose `stream subscriptions` as the supported live process-local
  state and describe its limitation explicitly.
  Rationale: `mori://shinzui/kiroku/packages/kiroku-store` has no public durable
  checkpoint inventory. Honest empty output is safer than coupling the CLI to a
  private schema or labeling transient state as durable.
  Date: 2026-08-08

- Decision: Make aggregate snapshot discriminators explicit inputs and keep the
  known workflow tuple automatic.
  Rationale: The standalone executable has no application codecs. Requiring the
  candidate tuple preserves the three-component compatibility rule without
  extending `OpsEnv` ahead of plan 208.
  Date: 2026-08-08

- Decision: Require typed confirmation for human-mode PGMQ purge, matching the
  hard-delete rail, while leaving JSON automation governed by `--force`.
  Rationale: Purge and hard delete are the two irreversible deletion operations;
  a target-name confirmation catches interactive selection mistakes without
  making scripts prompt.
  Date: 2026-08-08


## Outcomes & Retrospective

Completed on 2026-08-08. `keiro-ops` now mounts all nine database-only command
domains under one root and keeps the plan-206 rendering, schema handshake, and
preview/`--force` contract. Seven new domain modules wrap public owning-library
operations; the supporting Keiro APIs make previews exact without adding any CLI
SQL. The root and nested help trees were exercised, including the planned
`outbox dead-letters list` and `pgmq dlq` hierarchy.

The ephemeral PostgreSQL acceptance transcript is represented directly by the
handler tests:

```text
outbox handlers: surfaces dispatch dead letters through the supported API [PASS]
inbox handlers: previews poison marking and GC without bypassing inbox APIs [PASS]
pgmq handlers: previews and redrives a DLQ entry, which is then consumable [PASS]
projection handlers: reports lag, reaches zero after checkpointing, and prunes only the named dedup rows [PASS]
shard handlers: previews exact buckets, relinquishes them, and another worker re-leases them [PASS]
snapshot handlers: refuses uncovered truncation, passes matching coverage, and deletes advisories [PASS]
stream handlers: reads causation and applies lifecycle, truncate-marker, and permanent-delete operations [PASS]
```

Validation completed with `cabal test keiro-ops-test` (23 examples),
`cabal test keiro-test` (441 examples), and `cabal test keiro-pgmq-test`
(58 examples, 2 pre-existing pending cases). The repository-wide `just verify`
gate also passed, including all DSL conformance suites, `jitsurei-test`, migration
tests, generated-corpus checks, and OKF validation.


## Context and Orientation

Read plan 206's Context first if the package does not yet feel familiar; this
plan only adds `Keiro.Ops.<Domain>` modules following its conventions and adds
`keiro-pgmq` to `keiro-ops.cabal`'s dependencies. Every command below wraps an
exported library function. The final inventory includes the narrow owning-library
inspection APIs added while implementing exact previews:

Outbox (`keiro/src/Keiro/Outbox.hs`): `countOutboxBacklog`, `listOutbox`,
`lookupOutbox`, `listStuckOutbox`, `listSentOutboxGcCandidates`,
`requeueStuckOutbox`, `garbageCollectSent`,
`outboxMaintenancePass`. Dispatch dead letters
(`keiro/src/Keiro/DeadLetter.hs`): `listDispatchDeadLetters`. There is no
outbox-dead-letter *redrive* API; if triage shows one is needed, it is a
keiro-library addition first (MasterPlan 31's constitutional rule) — record the
gap in Surprises & Discoveries rather than writing SQL.

Inbox (`keiro/src/Keiro/Inbox.hs`): `listInbox`, `lookupInbox`,
`listCompletedInboxGcCandidates`, `countInboxBacklog`,
`garbageCollectCompleted`, `markFailedTx` (transaction-level; wrap in
`runTransaction`).

pgmq (`keiro-pgmq/src/Keiro/PGMQ/Dlq.hs`): `readDlq`, `redriveDlq`, `purgeDlq`,
`archiveDlq`, `archiveDlqEntry`, `archiveDlqEntryById`; the generic standalone
surface decodes raw JSON through `aesonJobCodec @Value` while preserving the
versioned dead-letter wrapper — render the envelope fields (original message id,
enqueue time, dead-letter reason) plus the raw JSON payload; the
telemetry/envelope contract is
`docs/adr/0001-keiro-pgmq-job-processing-telemetry-contract.md` and must not be
bypassed. Queue names come from the operator (`--queue`).

Projections (`keiro/src/Keiro/ReadModel.hs`): `readSubscriptionPosition`,
`storeHeadPosition`, `categoryHeadPosition` — the position triple that yields a
lag column; dedup pruning via
`Keiro.Projection.countAsyncProjectionDedupForBefore` and
`pruneAsyncProjectionDedupForBefore`.

Shards (`keiro/src/Keiro/Subscription/Shard.hs`): `ownershipSnapshotFor`,
`shardCountSnapshot`, `relinquish` (the coordinator-free failover means
relinquish is safe: another worker leases the freed buckets).

Snapshots (`keiro/src/Keiro/Snapshot/Schema.hs`): `lookupSnapshotRow` and
`deleteSnapshotRow` provide row lookup/inspection and advisory deletion —
render stream, version, codec discriminators (`state_codec_version`,
`regfile_shape_hash` / the workflow `keiro.workflow.stepmap.v1` sentinel), and
sizes; row deletion (snapshots are advisory — deleting one only forces a full
replay, per `docs/adr/0003-snapshot-compatibility-is-a-three-component-discriminator.md`).
The *truncation preflight* command implements the check in
`docs/user/operations.md` §Stream Truncation: given a stream and a proposed
truncate-before version `V+1`, verify a valid snapshot at version ≥ `V` exists
for the stream's current discriminators and report pass/fail with the evidence.

Streams (`kiroku-store`, path per `mori registry show shinzui/kiroku --full`):
`Kiroku.Store.Read.readStreamForward`/`getStream` for `stream show`;
`Kiroku.Store.Lifecycle.{softDeleteStream, hardDeleteStream, undeleteStream,
setStreamTruncateBefore, clearStreamTruncateBefore}`;
`Kiroku.Store.Subscription.subscriptionStates` for live process-local state;
`Kiroku.Store.Causation` walkers for `stream causation <event-id>`. Event
payloads are self-describing JSON — display is generic; validation against
application codecs is not this binary's job (it has no codecs — that is the
embedding surface, plan 208).

ADR context per `agents/skills/exec-plan/ADR.md`: the operator-command contract
ADR created by plan 206 governs everything here (cite it from each module
haddock); ADR 1 (pgmq envelope), ADR 3 (snapshot discriminators), ADR 9 (schema
verification) as noted inline. No new ADR is expected from this plan.


## Plan of Work

One milestone per domain; each is the same shape — a `Keiro.Ops.<Domain>` module
whose handlers take `OpsEnv` and return table+JSON-renderable results, wired into
the command tree, with handler-level tests against ephemeral Postgres. Command
sketches (final flag spellings follow plan 206's conventions):

`keiro-ops outbox`: `backlog`, `list --source <source> [--status]
[--destination] [--limit]`,
`show <id>`, `requeue-stuck --force [--older-than d]`, `gc-sent --force
[--older-than d]`, `maintenance-pass --force`, `dead-letters list --dispatcher
<name> [--limit]`.

`keiro-ops inbox`: `backlog`, `list --source <source> [--status] [--limit]`,
`show <source> <message-id>`, `gc --force [--older-than d]`,
`mark-failed --force <source> <message-id> --reason <text>`.

`keiro-ops pgmq`: `dlq read --queue <q> [--limit]`, `dlq redrive --force
--queue <q> [--limit]`, `dlq archive --force --queue <q> [--entry <id>]`,
`dlq purge --force --queue <q>`.

`keiro-ops projection`: `position --subscription <s> [--category <c>]`
(subscription position, store/category head, computed lag), `prune-dedup --force
--projection <p> --before <ISO-8601-UTC>`.

`keiro-ops shard`: `status --subscription <s>` (ownership snapshot + counts),
`relinquish --force --subscription <s> --worker <id>`.

`keiro-ops snapshot`: `show --stream <name>`, `delete --force --stream <name>`,
`truncation-preflight --stream <name> --before <version>`.

`keiro-ops stream`: `show <name> [--from v] [--limit]`, `soft-delete --force
<name>`, `undelete --force <name>`, `hard-delete --force <name>` (typed
confirmation, per Decision Log), `truncate-before set --force <name> <version>`
(runs the snapshot preflight automatically and refuses on failure unless
`--skip-preflight`), `truncate-before clear --force <name>`, `subscriptions`
(live process-local subscription state), `causation <event-id>`.

Tests mirror plan 206's style: seed through the libraries (enqueue outbox rows
and dead-letter one; insert inbox rows through `runInboxTransaction`; enqueue and
dead-letter a pgmq job through `keiro-pgmq`'s test helpers; advance a
subscription; write snapshots via a snapshotted workflow or aggregate), then
drive handlers and assert structured results, previews mutating nothing, and each
mutation's library-level postcondition (e.g. redriven DLQ message consumable
again; truncation preflight failing without coverage and passing with it).


## Concrete Steps

All commands run from the repository root.

```bash
cabal build keiro-ops
cabal test keiro-ops-test
```

Commit per domain or per coherent group:

```text
feat(ops): add messaging and read-side domains to keiro-ops

MasterPlan: docs/masterplans/31-build-the-keiro-ops-operational-cli.md
ExecPlan: docs/plans/207-add-the-messaging-and-read-side-command-domains-to-keiro-ops.md
Intention: intention_01kzagac32ehp93amx1sfar2ab
```


## Validation and Acceptance

Acceptance per domain is the library-postcondition test plus one transcript
apiece added to this plan's Outcomes: a dead-lettered outbox row surfaced by
`outbox dead-letters list`; an inbox poison row marked failed and GC'd; a pgmq
DLQ message redriven and re-consumed; a projection lag readout that goes to zero
after the projection catches up; a shard relinquished and re-leased by another
worker id; a truncation preflight refusing without snapshot coverage and passing
with it. The stream domain's destructive path is validated only against the
ephemeral test store.


## Idempotence and Recovery

All mutations wrap idempotent or guarded library APIs; previews mutate nothing.
The two genuinely destructive commands (`stream hard-delete`, `dlq purge`) are
exactly the ones with the extra confirmation rail, and both operate on state the
runbook already classifies as operator-owned. Re-running any test is safe
(ephemeral template databases).


## Interfaces and Dependencies

Adds `keiro-pgmq` to `keiro-ops.cabal`. New modules: `Keiro.Ops.Outbox`,
`Keiro.Ops.Inbox`, `Keiro.Ops.Pgmq`, `Keiro.Ops.Projection`, `Keiro.Ops.Shard`,
`Keiro.Ops.Snapshot`, `Keiro.Ops.Stream`. Consumes plan 206's `OpsEnv`, render
helpers, and rails unchanged; must not extend `OpsEnv` (that is plan 208's
integration point per MasterPlan 31). Any missing library primitive discovered
here (e.g. outbox dead-letter redrive) is recorded and filed against the owning
library, never implemented as CLI-side SQL.
