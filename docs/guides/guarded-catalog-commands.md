---
type: Guide
title: Guarded Catalog Commands
description: Enforce a relational identity precondition atomically with a synchronous catalog command while keeping rich query views asynchronous.
docId: DOC-29
tags: [keiro, commands, projections, transactions]
generated:
  by: process:codex-cli
  at: 2026-10-12T03:25:00Z
---

# Guarded Catalog Commands

Use `runDomainCommandWithCatalogProjectionsGuarded` when a command may create
an aggregate only if a relational identity remains absent. The precondition
looks up a minimal synchronous identity index. A refusing result rolls back
the tentative event batch and carries the existing aggregate ID; a successful
result commits the batch and its inline projections together.

The runnable consumer example is
[`GuardedCatalogExample.hs`](../../keiro/test/GuardedCatalogExample.hs).
[`GuardedCatalogSpec.hs`](../../keiro/test/GuardedCatalogSpec.hs) exercises
same-database races, rollback, driver retries, archive/replay, and post-commit
query waits. Full lifecycle and performance acceptance is tracked in
[ExecPlan 306](../plans/306-support-atomic-relational-preconditions-for-synchronous-catalog-commands.md).
The initial measurements do not establish performance readiness or authorize
publication. Downstream adoption belongs to
`mori://shinzui/rei/plans/249-expose-categories-and-custom-properties-with-shared-typed-assignment-semantics`.

## Keep command authority small

The example's `state_note_identity` table maps four canonical, non-null values
— anchor type, anchor ID, property definition ID, and state ID — to the winning
note ID. Its primary key covers exactly those four values. Archive retains the
mapping; it does not make the identity available again. The index contains no
content, tags, provenance, display joins, or foreign key to an async row.

An independent owner maintains `state_notes` asynchronously from committed
events. Both owners are registered in the full catalog, but `commandSet`
contains only the identity owner's definition. `typedProjectionRebuildGroups`
includes every owner in the supplied set, even async-only owners. Supplying
`fullSet` intentionally couples admission to both groups. Separate owners and
groups provide independent availability only when real dependencies permit it.
See [Choosing A Projection](choosing-a-projection.md).

The application must normalize identity values identically before event
encoding and guard lookup, and reconcile legacy duplicate creation facts before
activating this unique index. The example trims identity IDs and case-folds the
anchor type. It has no deletion or re-anchoring command. Changing those policies
requires a migration and a fresh invariant proof. A creation path that bypasses
the precondition can encounter a unique violation; that operational fault is
never evidence of typed reuse.

## Match the transaction result

The order for an accepted domain decision is hydration and pure decision,
tentative append, all required catalog fences and serving bindings,
precondition, inline delivery, then commit. A catalog fault takes precedence
over a consumer duplicate refusal. Selected pure rejection/no-op decisions
invoke no precondition or catalog SQL. An early set/catalog mismatch retains
its existing precedence over command evaluation.

The example's complete command uses the public API:

```haskell
runDomainCommandWithCatalogProjectionsGuarded
  defaultRunCommandOptions
  (handler 1)
  (stream (noteId note))
  (CreateNote (notePayload note))
  catalog
  commandSet
  (noteGuard note)
```

`CatalogCommandOutcome (DomainProjectionCommandApplied outcome)` retains the
ordinary domain result. `PreconditionRefused (ExistingNote winner)` maps to
`(winner, False)`; an accepted creation maps to `(candidate, True)`.
`PreconditionRefused (GuardConfigurationFault detail)` is an application
configuration failure. `ensureStateNoteExample` preserves store, command,
guard-configuration, and catalog failures as separate constructors. Neither a
SQL fault nor a commit/transport uncertainty becomes a known duplicate.

Refusal contains no `CommandResult`, accepted event values, or committed global
position. Do not wait on the tentative candidate's rolled-back position.
No-op likewise provides no new committed position. A separately retained
winner receipt may be used when the application actually has one.

## Resolve the protected serving target

`CatalogPreconditionContext` has a private constructor. Inspect its
`catalogPreconditionBindings` only within the callback. Each binding names a
group, its optional serving revision, and its `PhysicalTargets`.

```haskell
case catalogPreconditionBindings context of
  [binding]
    | binding ^. #writeGroupId == identityGroup
    , binding ^. #writeRevisionId == Nothing ->
        case resolvePhysicalTarget identityTarget
               (binding ^. #writePhysicalTargets) of
          Just table -> do
            winner <- Tx.statement (notePayload note) (identityLookup table)
            pure (maybe (Right ()) (Left . ExistingNote) winner)
          Nothing -> pure (Left (GuardConfigurationFault "identity target missing"))
  _ -> pure (Left (GuardConfigurationFault "unsupported identity serving binding"))
```

The SQL statement quotes the returned schema and table with
`Keiro.Connection.qualifyTable`. The ordinary example supports a legacy
binding explicitly; schema-versioned applications must dispatch each supported
serving revision to its corresponding query. Validate expected target membership
before invoking the runner. Never substitute an old table, choose the first
compiled revision, or query a staging target on an unsupported binding.
Accepted delivery receives the same bindings the guard inspected. Retaining
the context after return does not retain locks or authorize another transaction.

## Respect the callback contract

Return `Left refusal` to refuse and `Right ()` to continue. Keiro owns
condemnation and transaction control. Do not call `Tx.condemn`, issue
`BEGIN`/`COMMIT`/`ROLLBACK`, change isolation, manage savepoints, append
recursively, or acquire other stream/group locks. Keep production guards to
bounded indexed reads. The callback sees its own tentative append; it must not
interpret that event as independently committed identity authority.

Kiroku's append updates the store-wide `$all` row and retains its lock through
commit or rollback. A separate post-append lookup at `ReadCommitted` sees a
winner committed before that statement. This guarantee requires the same
database and store schema, synchronous identity maintenance, and participation
and invariant enforcement by every relevant live creation path. Arbitrary
external SQL and lagging subscription targets do not inherit it. Catalog group
locks protect lifecycle and serving bindings; they do not serialize identities.

Callbacks may run repeatedly. OCC conflicts retry from hydration and discard
the stale decision before any guard executes. Hasql driver retries repeat the
transaction body, resolve bindings again, and discard its prior guard result.
`retryLimit` bounds OCC attempts only; it does not bound the driver's separate
`40001`/`40P01` retry loop. Use connection/query timeouts where the application
requires an operational deadline.

Transactional row writes roll back on refusal. Sequence increments, session
advisory locks, SQL functions with external effects, and other nontransactional
effects can survive rollback and are outside the supported production contract.
The type does not sandbox arbitrary SQL or prove boundedness. Application
refusal values must not be logged as metric labels or generic span attributes.

Every post-append statement extends global append-lock ownership and can delay
unrelated writers. Rolled-back work still produces WAL and dead row versions
requiring vacuum. Compare mixed traffic, queue-inclusive ordinary-writer latency,
and sustained duplicate costs before production adoption; sequential correctness
tests do not establish those costs.

## Wait after commit

Keep rich views asynchronous and wait outside the append transaction when a
reader needs the projected write. Retain an accepted receipt's
`CommandResult.globalPosition`, pass it to `runQueryWithFreshness` using
`WaitForPosition`, and distinguish a ready result from `ReadModelWaitTimeout`
(committed, view pending), a view configuration/lifecycle error, and a store or
transport fault. Resume the worker and retry the query with the same receipt;
do not reissue creation because the view is pending. The example's test does
this with a paused worker and then catches up through public catalog delivery.
See [Asynchronous Projections](asynchronous-projections.md#read-your-write-after-commit).

Committed creation facts carry identity, content, tags, and provenance. Normal
catalog replay reconstructs both owners through their separate groups without
invoking the command precondition. Archive continues to reuse the first note
and preserves its original payload.
