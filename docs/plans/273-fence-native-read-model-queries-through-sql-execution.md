---
id: 273
slug: fence-native-read-model-queries-through-sql-execution
title: "Fence native read-model queries through SQL execution"
kind: exec-plan
created_at: 2026-09-08T21:01:53Z
intention: "intention_01m1pbbrwpe7kv867rfhs7mx9n"
---

# Fence native read-model queries through SQL execution

## Purpose / Big Picture

A native query must not return cleared or partly replayed data when a rebuild
starts after its availability check. Fix the native runtime and provide a public
transaction boundary for a compound SQL query observing several registered models.
This is required by mori://shinzui/meibo/plans/16-adopt-the-typed-projection-catalog-and-rebuild-groups
in support of mori://shinzui/koyomi/masterplans/1-bootstrap-koyomi-as-a-native-organizational-calendar-service.
No application should import Keiro's hidden rebuild modules or duplicate registry SQL.

## Progress

- [x] (2026-09-08) Confirm the released 0.16.0.0 query runner checks metadata in a separate transaction; Hackage and upstream package tags still identify 0.16.0.0 as the latest release.
- [x] (2026-09-08) M1: ordered group/model locks and the public non-empty compound query boundary are implemented; ordinary queries use it after freshness waiting.
- [x] (2026-09-08) M2 positive acceptance: eight PostgreSQL examples pass, covering actual catalog rebuild, versioned promotion, compound groups, rebuild-first refusal, group availability and concurrent registration/schema changes. Blocking assertions use pg_blocking_pids.
- [x] (2026-09-08) M2 negative acceptance: removing only the group shared lock makes real versioned promotion proceed past the held reader; the blocking-graph assertion fails. Restore the lock before repository verification.
- [x] (2026-09-08) M3 documentation: reconcile ADR-34, the public read-model guide and changelog; strict ADR (39 concepts) and user-documentation (25 concepts) validation and formatting pass. Release and Meibo adoption remain separate from this local fix.
- [x] (2026-09-08) M3 verification: repository-wide `nix develop -c just verify` exits zero, including core (640 examples), PGMQ (58 examples, two pending), operations (48 examples), DSL (719 examples plus conformance suites), Jitsurei, strict documentation/policy gates and migrations (36 examples). The owned PostgreSQL server shuts down successfully. Formatting and diff checks pass.

## Surprises & Discoveries

The private write lock helper is not a suitable read API: it tests writes_allowed,
not reads_allowed. Registry-row locks alone do not cover versioned promotion, which
changes group state and physical tables without updating every read-model row.
Lock groups first, then models, and hold those locks through application SQL.

## Decision Log

Use the existing read-model registrations as the authority for owning groups.
Discover names/groups, lock every group in deterministic order, lock every model
in deterministic order, and revalidate that membership did not change. Reject a
changed registration rather than running SQL under the wrong group. This preserves
single-owner DSL declarations while allowing a compound query to name all the models
it actually observes. Freshness polling happens before these locks; no cursor wait
may hold a rebuild lock. Schema and status are checked again under the locks.

## Outcomes & Retrospective

The first focused acceptance run passes all eight new examples in 1.9622 seconds.
Actual versioned promotion waits for the native reader, which returns the old row
count; after promotion the same model sees the rebuilt count. Removing only the
group lock fails that test with "database lock state was not observed". Model
registry locks alone therefore do not cover versioned promotion. The latch has
a 60-second server-side fallback, which bounds failure cleanup. Existing Meibo
sequential refusal tests alone are not concurrency evidence. Consumer adoption requires a supported dependency
revision; no local-only source pin or unpublished release is claimed to be available.

Repository verification uses an isolated PostgreSQL data/socket directory and
the ordinary `just verify` recipe. Its wrapper stops only that owned server.
The complete recipe and owned-server shutdown exited zero. The DSL suite performs
nested generated-workspace compilation, which explains its longer quiet periods.
All verification processes were joined before committing. The local fix is
complete; release and Meibo adoption remain explicit follow-up requirements.

## Context and Orientation

`keiro/src/Keiro/ReadModel.hs` owns runQuery, freshness waiting and typed schema errors.
`keiro/src/Keiro/ReadModel/Schema.hs` owns registry SQL. Group rebuilds and versioned
promotion in `keiro/src/Keiro/ReadModel/Rebuild/` lock group rows before mutation.
A PostgreSQL shared row lock allows concurrent readers but conflicts with these
lifecycle updates. Locking the registry row additionally prevents its schema or
owning group changing before the query finishes. Read-committed transaction statements
acquire fresh snapshots after lock acquisition; query SQL therefore executes after
all relevant lifecycle facts have been validated.

[ADR-26](../adr/0026-projection-catalogs-separate-query-target-group-and-handler-identities.md)
separates query, target and rebuild-group identities; do not invent a single supplier
for a compound query. [ADR-34](../adr/0034-online-projection-rebuilds-use-schema-versioned-target-generations.md)
requires a group lock around serving generation use. Its claim about native query
safety needs qualification until this fix is verified. No migration is needed.

## Plan of Work

### M1: native atomic validation

Add transaction-composable schema locking with explicit missing, unavailable and
changed-registration outcomes. Add a public requirement value derived from a
ReadModel's name/version/shape and a runner taking a non-empty collection of those
requirements plus one SQL transaction. Validate all requirements before executing
SQL. Ordinary runQuery must delegate to this boundary after its existing wait.
Preserve existing errors for missing registrations, stale shape/version and non-live
model status. Use explicit errors for unavailable groups and changed group bindings.

### M2: concurrency acceptance

Extend the PostgreSQL tests to hold a query inside its SQL transaction, observe its
backend state, and start a real rebuild. Prove the rebuild is blocked by that reader
through pg_blocking_pids, then release the reader and observe the original result
and successful rebuild start. Repeat relevant coverage for compound model sets,
non-live groups, schema drift and a registration changed during lock acquisition.
Also start a rebuild before a query obtains its lock: the query must refuse rather
than execute against cleared tables. Remove locking temporarily and demonstrate a
specific regression failure, then restore and rerun.

### M3: verification and handoff

Update public query documentation, changelog and the relevant ADR with the proven
lock ordering and the limits of arbitrary caller-owned SQL. Run focused tests and
repository verification. Record exact commands/results and leave release/adoption
explicit until a supported revision can be consumed by Meibo. Do not publish merely
to make a local dependency pin appear usable.

## Concrete Steps

Run from the Keiro repository in its Nix development shell:

```bash
nix develop -c cabal test keiro-test --test-options='--match Keiro.ReadModel'
nix develop -c cabal build all
nix develop -c just verify
nix fmt
```

Find dependency sources with Mori before using new APIs. Test fixtures provide fresh
disposable PostgreSQL databases; no development or deployed database reset is needed.

## Validation and Acceptance

Successful queries return the existing typed result. Missing, stale and rebuilding
models refuse before the supplied SQL executes. A compound query protects every named
model independent of declaration order. An observed in-flight query prevents group
rebuild/promotion from replacing its data until it finishes. A query that loses the
race refuses unavailable data. Freshness waits retain their timeout and missing-cursor
behavior and acquire no long-lived locks while polling. Existing runtime tests pass.

## Idempotence and Recovery

Tests are repeatable against disposable fixtures. Changes are additive public API
and a corrected native execution path, with no schema or dependency pin change.
Restore deliberate mutations before validation or commits. Keep publication and
consumer adoption distinct from local implementation evidence.

## Interfaces and Dependencies

The public compound runner accepts non-empty model requirements and an ordinary
Hasql transaction. It returns Either ReadModelError result. ReadModel-derived
requirements carry the exact registry name, version and shape; they do not claim to
inspect arbitrary SQL or infer undeclared observed models. The native Schema module
owns lock SQL. Existing Kiroku Store transaction handling remains the executor.
