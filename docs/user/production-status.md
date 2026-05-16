# Production Status

Keiro v1 is production-shaped for controlled early use. It is not yet a
turnkey, externally polished framework.

## What Is Implemented

The current library includes:

- typed stream names;
- event codecs with schema versions and upcasters;
- the `EventStream` aggregate contract;
- command execution with hydration, replay, decision, optimistic append, and
  retry;
- same-transaction SQL continuations for inline projections;
- advisory snapshots;
- read-model metadata, consistency modes, and position waits;
- async projection helpers with idempotency expectations;
- event-sourced process managers;
- durable timer storage and worker helpers.

The repository test suite exercises these paths against an ephemeral PostgreSQL
database.

## Good Fit Today

Keiro is a reasonable fit when:

- your team controls the application and deployment environment;
- PostgreSQL is already part of the system;
- you want a library, not a separate workflow/event-store server;
- you can write explicit codecs and migration tests;
- you can make async handlers idempotent;
- you are comfortable with low-level Haskell APIs while v1 ergonomics mature.

## Not A Good Fit Yet

Keiro is not yet a good fit when:

- you need a stable public API for third-party consumers;
- you need exactly-once async projections without user-side idempotency;
- you need Temporal-style deterministic durable execution;
- you need built-in schema migration tooling for user read models;
- you need a complete sample application and extensive Haddocks before adoption;
- your deployment cannot run PostgreSQL 18+.

## Known v1 Limits

### Async projections are at-least-once

The current Shibuya/Kiroku subscription boundary does not combine user SQL and
checkpoint advancement in one transaction. Async projection handlers must be
idempotent.

Inline projections can be transactional with the command append.

### Durable execution is deferred

V1 process managers and timers cover saga-style coordination and time-based
wakeups. The v2 deterministic durable-execution runtime is intentionally
deferred.

### APIs are low-level

The command, projection, read-model, process-manager, and timer APIs expose the
runtime primitives directly. Higher-level ergonomic facades are future work.

### Migration ownership is split

Keiro initializes its own metadata tables, but application read-model tables,
codec evolution, and deployment sequencing remain application responsibilities.

## Recommendation

Use Keiro v1 in production only with explicit guardrails:

- pin dependency revisions;
- run the full test suite in CI;
- add application-level codec and projection idempotency tests;
- document operational repair procedures;
- treat API changes as expected until the library reaches a stronger stability
  milestone.

For an internal system with those controls, the core paths are ready to trial.
For broad external adoption, the library needs more examples, Haddocks, release
discipline, and the remaining v1.x ergonomics.
