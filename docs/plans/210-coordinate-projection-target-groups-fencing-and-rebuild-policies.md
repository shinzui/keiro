---
id: 210
slug: coordinate-projection-target-groups-fencing-and-rebuild-policies
title: "Coordinate projection target groups fencing and rebuild policies"
kind: exec-plan
created_at: 2026-08-07T23:36:51Z
intention: "intention_01kzf95908e14b29bxjb4yhfe0"
master_plan: "docs/masterplans/32-build-typed-projection-catalogs-and-safe-coordinated-rebuilds.md"
---

# Coordinate projection target groups fencing and rebuild policies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this plan, the rebuild lifecycle is coordinated by the catalog's rebuild group rather
than by one `ReadModel` and one table. Keiro transitions every target in a group under one
database fence, clears only clear-before-replay targets in one compatible operation, preserves
brownfield reconcile targets, resets derived dedup/subscription state, and promotes or abandons
the group atomically.

Both inline and asynchronous live writers consult the same group state in their write
transaction. A writer already holding the group lock finishes before preparation; a later
writer receives a typed fenced result and performs no event append, dedup insert, or target
write. The behavior is visible in PostgreSQL integration tests covering normalized foreign-key
tables, mixed clear/preserve groups, and concurrent live traffic.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add Keiro-owned group lifecycle schema and migrate existing single-read-model registry
      state without touching application tables.
- [ ] Implement validated, atomic group preparation for multi-target clear/preserve policies and
      derived dedup/subscription reset sets.
- [ ] Enforce the same group fence in inline and async live write transactions; retain the legacy
      one-read-model compatibility path.
- [ ] Implement atomic group promotion and abandonment, add concurrency/policy tests, amend the
      catalog ADR, and pass focused and full verification.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Make a rebuild group, not a query model or physical target, the registry and fence
  identity.
  Rationale: One live transaction can update several normalized targets, and foreign-key-related
  targets must reset and promote together. Query and table identities cannot express this unit.
  Date: 2026-08-07

- Decision: Prepare all clear targets with one PostgreSQL `TRUNCATE` statement inside the group
  transition transaction.
  Rationale: Sequential truncates can fail for foreign-key-related tables even when all are meant
  to be cleared. One validated target set lets PostgreSQL check the operation as a whole.
  Date: 2026-08-07

- Decision: Treat clear and preserve targets as a valid mixed group.
  Rationale: Brownfield roots may lack complete event history while derived children can be fully
  rebuilt. Atomic lifecycle does not require identical reset policy; it requires safe replay
  coverage and one fence.
  Date: 2026-08-07

- Decision: Return a typed fenced outcome from live application rather than blocking until an
  operator finishes the rebuild.
  Rationale: Holding application requests indefinitely hides operational state. Serialization at
  the transaction lock prevents reset races; a typed result gives the caller an explicit retry or
  service-unavailable choice.
  Date: 2026-08-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This plan hard-depends on [plan 209](209-define-and-validate-the-typed-projection-catalog-runtime-contract.md).
That plan supplies opaque group and target identities, reset and replay policies, derived
dedup/subscription sets, and `ValidatedProjectionCatalog`. Do not copy those declarations into
the rebuild module.

`keiro/src/Keiro/Projection.hs` currently protects inline and async application by locking the
registry row named by a `ReadModel`. The inline path runs inside the command transaction, so a
fence failure can roll back the event append and every projection write. The async path checks
the fence before inserting its dedup marker and applying a recorded event. Preserve those
transaction boundaries while changing the lookup key from an individual read model to the
catalog's rebuild group.

`keiro/src/Keiro/ReadModel/Rebuild.hs` currently starts a rebuild for one `ReadModel`, issues
one-table `TRUNCATE`, resets caller-supplied projection names, resets a subscription cursor, and
uses dedup presence during promotion. This plan replaces preparation and group state but does
not implement history scanning or the final completeness proof; [plan 211](211-replay-catalogued-projections-deterministically-and-resumably.md)
does that. The controlled body used here exists only to prove lifecycle and locking.

`keiro/src/Keiro/ReadModel/Schema.hs` and the SQL migrations in `keiro-migrations` own the
current `keiro.keiro_read_models` schema. `keiro.keiro_projection_dedup` stores async idempotency
keys separately. Inspect the migration manifest, lock file, expected-schema fixtures, and
bootstrap schema before allocating a new migration. Never edit a released migration.

A group has states equivalent to live, rebuilding, and failed. **Preparation** is the one
transaction that locks/transitions the group, clears the selected application tables, preserves
the others, and resets only catalog-derived Keiro state. **Promotion** is the one transaction
that accepts plan 211's completion evidence and returns the whole group to live. **Abandonment**
records failure evidence and keeps live writers fenced; it is not a destructive rollback of
partially rebuilt application data.

[ADR 9](../adr/0009-keiro-owns-live-schema-verification-under-pg-migrate.md) requires Keiro's
registry changes to ship as pg-migrate assets with expected-schema verification while leaving
application DDL consumer-owned. [ADR 4](../adr/0004-evolution-changes-are-gated-at-the-earliest-sound-boundary.md)
requires catalog validation before runtime assembly. The ADR created by plan 209 is also
normative and must be amended with the final group state machine and locking protocol. The
cross-repository brownfield constraint remains
`mori://shinzui/mori/okf/adrs/concepts/ADR-20`.


## Plan of Work

### Milestone 1: Persist the group lifecycle

Design the group state machine in `keiro/src/Keiro/ReadModel/Rebuild.hs` and
`keiro/src/Keiro/ReadModel/Schema.hs`. Persist a group identifier, catalog fingerprint, state,
active rebuild-run identifier, version/shape evidence needed by existing query gates, timestamps,
and failure evidence. Query-model registry records refer to the group they observe. If retaining
`keiro.keiro_read_models` is the least disruptive representation, add a group table and foreign
key; otherwise introduce a versioned replacement and a compatibility view. Do not overload one
row per target with group semantics.

Allocate the next Keiro migration rather than editing bootstrap or released SQL. Update the
embedded migration manifest, integrity lock, and expected schema in the same change. The forward
migration must map each existing read model to a deterministic singleton legacy group, preserving
its current liveness and rebuild state. A downgrade, if Keiro's migration policy requires one,
must refuse lossy collapse of a multi-target group rather than silently selecting one table.

Add registration/upsert operations that consume the complete validated catalog. Registration
must verify all groups and query-model bindings before changing any row, then write them in one
transaction. A catalog validation failure must perform no SQL. Milestone 1 passes when an old
single-table fixture upgrades without data loss, a new two-target group registers once, and
schema verification passes.

### Milestone 2: Prepare a group atomically

Replace the one-table preparation entry point with `beginGroupRebuild`. It accepts a
`ValidatedProjectionCatalog`, a `RebuildGroupId`, and explicit operator metadata, rechecks the
catalog fingerprint against the registered value, acquires an advisory or row lock in a documented
order, verifies the group is live, and creates a rebuild run. It then renders only catalog-owned
SQL for the declared qualified targets.

Quote every schema and table component through the existing safe identifier helper. Collect all
`ClearBeforeReplay` targets and issue one `TRUNCATE TABLE t1, t2, ...` statement in stable
dependency order. Do not add `CASCADE`: an undeclared referencing table must make preparation
fail instead of being erased. Leave every `PreserveAndReconcile` target untouched. A group with
no clear targets performs no truncate but still transitions under the fence.

Derive projection dedup keys and subscription/checkpoint identities from the catalog. Reset only
state belonging to replayable group members and record exactly what was reset. Do not accept a
caller-supplied `[Text]`. All transition, truncate, and reset work commits together; any SQL error
leaves the group live and its application targets unchanged. A controlled callback running after
commit may stand in for replay during this plan, but no public API may provide a generic bypass
around the fence.

Integration tests create a normalized parent/child schema with foreign keys. They demonstrate
that the one multi-table truncate succeeds, that sequential truncate is not used, that a
preserved brownfield parent survives, and that an external undeclared reference causes the whole
preparation transaction to roll back.

### Milestone 3: Fence inline and async writers by group

Update `keiro/src/Keiro/Projection.hs` so catalog-derived inline application acquires the lock for
each distinct group touched by the selected projections, in sorted `RebuildGroupId` order, before
the event append and before any handler. A command whose projections all share one group takes one
lock. A command spanning several independent groups may lock several groups in stable order to
avoid deadlock; catalog validation has already rejected one transactional owner split across
groups.

Return `ProjectionWriteFenced groupId runId` or the repository's equivalent typed outcome. When
fenced, the transaction must not append an event, execute a projection, or leave a partial result.
An application may map that outcome to retry or unavailability outside Keiro. Preserve the
existing unmanaged `runCommandWithProjections` behavior for legacy callers, mark its lack of
catalog fencing in Haddock, and add a catalog-derived entry point rather than silently changing
the old function's semantics.

Update async application to lock the same group before dedup insertion and handler execution.
A fenced async event does not advance a subscription checkpoint, insert a dedup key, or apply a
target write. Concurrency tests hold an in-flight live transaction, start preparation on another
connection, and prove preparation waits; after preparation wins the lock, new inline and async
writes receive the fenced result immediately after their lock check.

### Milestone 4: Promote or abandon the whole group

Implement internal completion-token types that plan 211 can construct only after persisted
verification. `finishGroupRebuild` locks the group/run, confirms the run and catalog fingerprint,
accepts the opaque completion token, writes promotion evidence, and makes all query-model bindings
live in one transaction. No single target or query model can be promoted independently.

`abandonGroupRebuild` records a structured reason and leaves the group fenced. A later resume of
the same run remains plan 211's responsibility; an operator may explicitly start over only through
an API that validates the group and records the discarded run. Do not attempt to restore cleared
application data automatically.

Amend the catalog ADR with the group state machine, lock order, multi-table truncate policy,
typed fence result, and failure semantics. Update public API docs and the changelog. Milestone 4
is complete when promotion/abandonment and race tests pass, migration verification passes, and
`just verify` succeeds.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/keiro`. First inspect current Keiro migration
conventions and the plan-209 public types:

```console
rg -n "keiro_read_models|projection_dedup|Migration" keiro-migrations keiro/src
sed -n '1,280p' keiro/src/Keiro/ReadModel/Rebuild.hs
sed -n '1,280p' keiro/src/Keiro/Projection/Catalog.hs
```

Allocate migrations with the repository's existing generator or manifest workflow discovered by
that inspection. Do not invent a second numbering mechanism. After editing migration assets, run:

```console
nix fmt
cabal test keiro-migrations-test
cabal test keiro-test
```

Expected successful tail:

```text
Test suite keiro-migrations-test: PASS
Test suite keiro-test: PASS
```

Run the strict ADR check after amending the plan-209 ADR:

```console
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Run all gates last:

```console
just verify
```

Record allocated migration identifiers, the final state names, lock query, and concurrency test
timings in Progress or Surprises & Discoveries. Never search `/nix/store`; resolve dependency
source through Mori if a pg-migrate or Hasql API must be checked.


## Validation and Acceptance

Acceptance requires PostgreSQL integration evidence:

1. Upgrade a fixture containing the current single-read-model registry. Its logical identity,
   state, table data, version, and shape remain intact and it belongs to a deterministic singleton
   legacy group. Register a new two-target group without fake query-less read models.
2. Prepare a parent/child group whose two targets are clear-before-replay. Both tables become
   empty through one group transaction despite their foreign key. No Keiro migration creates or
   alters either application table.
3. Prepare a mixed group with a preserved brownfield parent and a clear derived child. The parent
   row with no event history survives; the child is empty. An intentionally undeclared foreign-key
   reference causes preparation to fail and both targets retain their original rows.
4. Assert that the dedup/subscription reset set equals the catalog-derived group membership.
   There is no public group API accepting projection-name, target, or subscription lists.
5. Hold an inline write open before it commits and begin rebuild concurrently. Preparation waits
   and then observes the committed write before clearing. Once the group is rebuilding, a new
   inline command returns a typed fenced result and leaves the event store and targets unchanged.
6. Repeat for an async apply. A fenced apply leaves the target, dedup table, and subscription
   checkpoint unchanged. Use two groups in reverse caller order and prove the sorted lock order
   prevents deadlock.
7. Attempt to promote one target, use the wrong run ID, or use a stale catalog fingerprint. Each
   is rejected. A valid opaque completion token promotes every query-model binding atomically.
   Abandonment records failure and keeps writers fenced.
8. Legacy single-read-model functions still compile and have documented unmanaged semantics.
   `cabal test keiro-migrations-test`, `cabal test keiro-test`, ADR validation, and `just verify`
   pass.


## Idempotence and Recovery

Catalog registration is an idempotent upsert only when the durable group identity and fingerprint
match. A conflicting fingerprint returns a typed drift error and changes no rows. Migration
application follows pg-migrate's transactional and integrity-lock conventions and can be retried
after correcting a failure.

`beginGroupRebuild` is not blindly repeatable: a second call for a live group may create a new run,
but a call for an already rebuilding group returns its run metadata and requires explicit resume
or abandon. Transaction failure during preparation restores the pre-call registry, dedup,
subscription, and application-table state. Failure after preparation cannot reconstruct cleared
data; keep the group fenced and use plan 211's persisted replay resume or an explicit start-over.

Never repair a failed migration by editing a released SQL file or manually changing the migration
lock. Add a new forward migration. Never use `CASCADE`, disable foreign keys, or mark the group live
as a recovery shortcut.


## Interfaces and Dependencies

`Keiro.Projection.Catalog` from plan 209 is the only source of group membership, target reset
policy, projection/dedup identities, and fingerprints. `Keiro.ReadModel.Rebuild` owns effectful
lifecycle types and operations. The semantic surface is:

```haskell
data ProjectionWriteFence
  = ProjectionWritesAllowed
  | ProjectionWriteFenced RebuildGroupId RebuildRunId

data GroupRebuildHandle
data GroupCompletionToken

beginGroupRebuild
  :: ValidatedProjectionCatalog
  -> RebuildGroupId
  -> RebuildRequest
  -> Eff es (Either RebuildStartError GroupRebuildHandle)

finishGroupRebuild
  :: GroupRebuildHandle
  -> GroupCompletionToken
  -> Eff es (Either RebuildFinishError ())

abandonGroupRebuild
  :: GroupRebuildHandle
  -> RebuildFailure
  -> Eff es ()
```

The exact effect rows follow current Keiro conventions. `GroupCompletionToken` has no public
constructor; plan 211 obtains it only through persisted completion verification. A narrowly scoped
internal replay authorization may bypass the live fence for the active run, but ordinary callers
cannot construct it.

Use current Hasql transactions and the project's qualified-table quoting helper. Use the existing
pg-migrate integration and `keiro-migrations` package for Keiro-owned schema only. Before changing
pg-migrate or Hasql usage, locate their registered source with `mori registry search`, inspect it
on disk, and verify released versions/tags before changing bounds.
