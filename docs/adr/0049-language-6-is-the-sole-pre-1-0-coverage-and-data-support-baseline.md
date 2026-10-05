---
type: Architecture Decision Record
title: Language 6 is the sole pre-1.0 coverage and data-support baseline
description: A staged pre-1.0 breaking release ends retired source and data contracts, migrates supported functionality tests to Language 6, and deletes historical compatibility coverage and implementations.
timestamp: 2026-10-05T17:33:36Z
docId: ADR-49
status: Accepted
date: 2026-10-05
originatingPlan: docs/plans/304-retire-legacy-language-and-runtime-compatibility-before-keiro-1-0.md
---

# Language 6 is the sole pre-1.0 coverage and data-support baseline


## Context


Maintaining multiple DSL languages, obsolete runtime APIs, and historical-data
compatibility programs increases development, compilation, and test work. Merely
moving old suites to a new language number preserves most of their build cost.
Indefinitely keeping old readers and comparison binaries also preserves the cost
of contracts that the project no longer wants to support.

The project owner explicitly chose to end retired-contract data support, remove
its coverage, and keep only Language 6 positive DSL coverage. Old tests of
functionality that remains useful must be migrated to Language 6. Every known
consumer will be asked to migrate soon to facilitate the breaking release before
`1.0.0.0`.


## Decision


Use two distinct release boundaries. After Language 6 finalization, deprecation
release D still supports old source/data contracts while announcing their end.
A later breaking release R below `1.0.0.0` executes only Language 6 source and
supports an explicitly enumerated current runtime/data baseline. Actual versions
and policy identities are recorded during implementation, not guessed here.
This decision approves that transition; it does not claim the current working
tree already implements it.

At R, remove implementations, readers, probes, fixtures, compiled old corpora,
cross-version comparison programs, and recurring release/adoption gates whose
sole purpose is a retired contract. Do not preserve them as frozen components,
internal legacy modes, or mandatory old-build jobs. Their immutable archive is
the D tag and Git history. Package retirement does not require capturing every
consumer's private history once that history's contract is explicitly unsupported.

Every old assertion about a function that remains supported must have a passing
Language 6 replacement or a named equivalent current test before deletion.
Preserve meaningful error paths. Runtime-only tests remain current-runtime tests.
Remove old-only and duplicated cases; keep small negative refusal tests for
unsupported source and identifiable unsupported formats. Positive DSL fixtures,
including source embedded in tests, select 6. A historical filename or an old
writer's language number does not by itself make a codec form obsolete: policies
and accepted forms that Language 6 still uses remain current and tested.

Current-contract replay, serialized round trips, snapshot admission, process
partial-completion recovery, timer lifecycle, workflow continuation, idempotence,
and current identity vectors remain correctness obligations. Within that support
baseline, removing a required reader or changing data interpretation still needs
compatible evolution or an explicit new policy. An ended support promise is not
a claim that incompatible old/new observations are equal.

Prepare a migration request and readiness record for every known consumer during
D preparation. Source/API readiness and data/work readiness are distinct. R
adoption uses fresh current data or an explicit application-owned migration or
rebuild. Finish, migrate, or isolate unsupported queued, archived, timed, process,
workflow, and operator-replay work before adoption. A preamble edit does not do
this. A blocked consumer can remain on D without requiring R to keep its readers.
Publication does not authorize that consumer's deployment or data deletion.

Reject recognizable unsupported policy tags and obsolete ledger headers with
actionable guidance. Some old bytes lack an identifying marker; do not claim a
universal runtime detector or support merely because such bytes happen to decode.
Consumer migration/readiness records control adoption in those cases. Retain D's
build recipe for the old environment rather than add a legacy execution mode to R.

This support cutoff scopes the predecessor implementation/reader requirements in
[ADR-16](0016-source-language-provenance-wraps-the-semantic-keiro-dsl-graph.md),
[ADR-18](0018-runtime-semantics-use-capability-profiles-and-frozen-fold-identity.md),
[ADR-22](0022-generated-sidecars-use-role-bearing-names-and-forward-compatible-ledgers.md),
[ADR-24](0024-deterministic-ids-hash-utf-8-seed-bytes-and-are-frozen-replay-identity.md),
[ADR-41](0041-process-manager-reactions-use-accepted-witnesses-and-target-keyed-recovery.md),
and [ADR-47](0047-dsl-retirement-requires-complete-retained-history-evidence.md).
Their compatibility-preserving rules continue while the affected data contract is
supported, including D. At R, explicit retirement replaces the requirement to
preserve that retired interpretation or collect universal old-history evidence.
Current identity/recovery invariants are unchanged, and an old live environment
must not be silently treated as ready for new identity families.


## Consequences


The R gate measures one current coverage baseline. Supported old functionality is
migrated and redundant generated code is consolidated; old compatibility builds
and suites are actually deleted. Record cold/incremental compilation and warm-test
measurements, removed module/component counts, and disappeared comparison jobs.
Do not promise a percentage speedup or imply that renaming a suite saves time.

Some environments cannot upgrade without application-owned data work or a fresh
environment. That is an advertised breaking change, not a universal seamless
migration promise. This planning decision does not send migration notices, change
consumer repositories, deploy software, or delete stored data.

Earlier adoption/replay evidence remains historically valid for its old supported
scope. It is not rewritten as proof of R compatibility and is not a perpetual R
verification dependency. Current replay/recovery tests remain so maintenance
reduction does not eliminate the project's core runtime guarantees.
