---
id: 14
slug: harden-the-keiro-command-coordination-and-snapshot-paths-surfaced-by-the-2026-07-keiki-path-review
title: "Harden the keiro command, coordination, and snapshot paths surfaced by the 2026-07 keiki-path review"
kind: master-plan
created_at: 2026-07-12T05:07:40Z
intention: intention_01kxcz37ave9t8d6amvvxnemr6
---

# Harden the keiro command, coordination, and snapshot paths surfaced by the 2026-07 keiki-path review

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

In July 2026 a correctness review of keiro's keiki-facing surface — the command
execution path (`keiro/src/Keiro/Command.hs`), the coordination layer (process
managers, routers, projections, read models, the sharded subscription worker),
snapshots, and persistence down to kiroku's actual SQL — confirmed the foundation is
sound (atomic multi-event appends, race-free optimistic concurrency, gap-free
commit-ordered global positions, faithful `InFlight`-threaded hydration, effectively
once process-manager appends via deterministic event ids) and surfaced a set of
defects clustered in two themes. First, keiro discards keiki's failure witnesses:
several `Nothing`s that prove contract breaches (step/replay divergence, ambiguous
guards, silently dropped ε-edge transitions) are treated as routine no-ops. Second,
the coordination edges make correctness claims their code does not keep: the sharded
worker can checkpoint past an unprocessed event and silently lose it, the router's
"exactly-once-per-target" idempotency key is positional over an unstable resolver,
and the read-model rebuild runbook silently produces an empty table.

When this initiative is complete: no event is silently lost on rebalance (delivery is
ack-coupled everywhere); router idempotency survives resolver drift; a snapshot write
can never crash a command that already committed (the uninitialized-register-slot
thunk is caught at stream construction and again at encode time); every keiki failure
witness is either surfaced as a typed error or counted by a metric — never discarded;
a state-changing silent edge is rejected at stream-validation time (keiki EP-71's
default-on `StateChangingEpsilon` check, force-enabled at keiro's boundary) because
keiro's persistence model makes such transitions un-happen; rejected process-manager commands
have a dead-letter path instead of a permanent halt loop; retry exhaustion is
documented and replayable rather than a silent checkpoint advance; read-model rebuild
actually rebuilds; and `Strong` read-model queries are usable in a store with more
than one active category.

Standing assumption (user directive, 2026-07-12): keiki MasterPlan 16 (in the keiki
repository,
`docs/masterplans/16-harden-keiki-correctness-and-api-surfaces-surfaced-by-the-2026-07-architecture-review.md`)
is implemented FIRST. Every child plan here may rely on its outputs — most
importantly keiki EP-71's new `TransducerValidationWarning` constructors and keiki
EP-72's structured replay API (`applyEventsEither`, the seedable `replayEvents`
fold, `ReplayStepFailure`) — and must NOT duplicate work MP-16 already delivers. The
division of labor is explicit (revised 2026-07-12 with keiki MP-16): keiki owns
validator/replay agreement, head-recoverability, state-changing-epsilon *detection*
(EP-71's default-on `StateChangingEpsilon` warning), the structured failure
vocabulary, codec evolution, and the authoring-time emit/noEmit intent check; keiro
owns everything that exists because events-in-a-store are the only persistence —
*enforcement* of the replay-contract checks at the `ValidatedEventStream` boundary
(force-enabled, never weakenable by caller options), the operational enforcement of
the uninitialized-slot precondition (keiki EP-78 deliberately only documents it),
delivery/checkpoint coupling, dead-lettering, and telemetry.

In scope: the `keiro` and `keiro-core` packages, their tests, and documentation.
Out of scope: changes to keiki (MP-16 owns those); changes to kiroku beyond consuming
APIs it already exports (the ack-coupled subscription bridge already exists there);
the jitsurei example repos (outdated per the user — no plan may cite them as
evidence or migrate them); Kafka inbox/outbox internals beyond documentation
caveats; the keiro-dsl toolchain.


## Decomposition Strategy

The review's findings map onto four phases by blast radius and dependency shape.

Phase 1 is the keiki alignment foundation (EP-95). Because the standing assumption
is that keiki MP-16 lands first, the cheapest way to fix keiro's witness-discarding
theme is to consume keiki's new structured APIs directly rather than reconstruct
diagnostics around bare `Maybe`s: `Keiro.EventStream.Validate` must render keiki
EP-71's four new warning constructors (a compile-breaking exhaustive match), and the
duplicated `hydrate`/`hydrateFull` folds collapse into keiki EP-72's `replayEvents`
with typed failure reasons. Nearly every other plan that touches the command path
builds on the taxonomy this migration introduces, so it goes first.

Phase 2 fixes the data-loss and crash defects, which are independent of each other
and of Phase 1: the sharded worker's pull-time acking (EP-96), the router's
positional idempotency key (EP-97), and the snapshot subsystem's post-commit crash
and observability holes (EP-98). These are the highest-consequence items and can all
start immediately — they are grouped as a phase for review focus, not blocking.

Phase 3 makes keiro's own semantics honest about keiki's model: EP-99 force-enables
and pins keiki's state-changing-epsilon rejection at the stream boundary and turns
the remaining discarded witnesses (snapshot divergence, ambiguous guards, the bogus
no-op global position) into typed errors and counters — it hard-depends on EP-95's
taxonomy. EP-100 gives process managers a
dead-letter path for rejected commands and makes kiroku's silent retry-exhaustion
dead-lettering visible and replayable; it soft-depends on EP-99's error taxonomy.

Phase 4 is operational correctness that touches neither keiki nor delivery: the
read-model rebuild traps (EP-101) and the persistence polish items — truncation
guard, enrichment parity between the two append paths, messaging caveat
documentation (EP-102).

Alternatives considered: folding EP-99 into EP-95 (rejected: the migration must stay
mechanical and reviewable — it changes no semantics, while EP-99 deliberately does);
folding EP-97 into EP-100 since both touch router/PM (rejected: EP-97 is a narrow
correctness fix with its own test apparatus; EP-100 is failure-path design work);
a kiroku-side child plan for the subscription bridge (rejected: kiroku already ships
`subscriptionAckStream`; EP-96 only has to use it).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 95 | Migrate to post-MP-16 keiki and adopt the structured replay and step APIs | docs/plans/95-migrate-to-post-mp-16-keiki-and-adopt-the-structured-replay-and-step-apis.md | keiki MP-16 (external) | None | Complete |
| 96 | Ack-coupled sharded subscription delivery with rebalance-under-load coverage | docs/plans/96-ack-coupled-sharded-subscription-delivery-with-rebalance-under-load-coverage.md | None | None | Complete |
| 97 | Stable router idempotency keys derived from target stream names | docs/plans/97-stable-router-idempotency-keys-derived-from-target-stream-names.md | None | None | Complete |
| 98 | Snapshot subsystem hardening: uninit-register guards, read-side telemetry, and workflow write alignment | docs/plans/98-snapshot-subsystem-hardening-uninit-register-guards-read-side-telemetry-and-workflow-write-alignment.md | None | EP-95 | Complete |
| 99 | Silent-edge validation and divergence witnesses on the command path | docs/plans/99-silent-edge-validation-and-divergence-witnesses-on-the-command-path.md | EP-95 | None | Complete |
| 100 | Process-manager failure paths: dead-lettering rejected commands and surfacing retry exhaustion | docs/plans/100-process-manager-failure-paths-dead-lettering-rejected-commands-and-surfacing-retry-exhaustion.md | None | EP-99 | Complete |
| 101 | Read-model rebuild correctness: dedup reset, writer fencing, and Strong cursor semantics | docs/plans/101-read-model-rebuild-correctness-dedup-reset-writer-fencing-and-strong-cursor-semantics.md | None | None | Complete |
| 102 | Persistence polish: truncation guards, enrichment parity, and messaging caveat documentation | docs/plans/102-persistence-polish-truncation-guards-enrichment-parity-and-messaging-caveat-documentation.md | None | EP-95 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-95); the
external dependency names keiki MasterPlan 16.


## Dependency Graph

EP-96, EP-97, EP-101, and EP-102's non-replay items can start immediately and in
parallel — they touch delivery, the router, read models, and messaging docs, none of
which depend on the keiki migration. EP-95 starts as soon as keiki MP-16's EP-71 and
EP-72 are complete (the external hard dependency; MP-16's registry in the keiki
repository is the source of truth for their status).

EP-99 hard-depends on EP-95 because its divergence witnesses are expressed in the
vocabulary the migration introduces: the snapshot-divergence counter reads the typed
reason from keiki's `applyEventsEither`, and the ambiguity-vs-rejection split in
`CommandError` comes from adopting the structured step/replay failure types rather
than pattern-matching a bare `Nothing`. EP-98 soft-depends on EP-95 only for its
telemetry milestone (the decode-failure counter can land independently; the
divergence-adjacent pieces read better after the migration) — its
uninitialized-slot guards have no dependency and must not wait. EP-100 soft-depends
on EP-99 because dead-letter records for rejected commands should carry the new
taxonomy (a rejection dead-lettered as "ambiguous guards" versus "no matching edge"
is precisely the diagnostic value the plan adds), but its retry-exhaustion
documentation and replay tooling are independent. EP-102 soft-depends on EP-95 only
where its truncation guard reports failures through the migrated hydration errors.


## Integration Points

1. `CommandError` in `keiro/src/Keiro/Command.hs` (EP-95 defines, EP-99 and EP-100
   consume). EP-95 owns the post-migration shape: `HydrationReplayFailed` gains (or
   is joined by) structured detail from keiki EP-72's failure types, and command
   evaluation distinguishes ambiguity from rejection. EP-99 adds any
   divergence-specific constructors; EP-100 serializes these into dead-letter
   records. All three must agree that `commandErrorClass` (the low-cardinality
   `error.type` span attribute, Command.hs:570-578) gets one new class per
   constructor — no reuse of `"command_rejected"` for ambiguity.

2. `Keiro.EventStream.Validate` warning vocabulary (EP-95 renders, EP-99 hardens).
   EP-95 adds the exhaustive-match render arms for keiki EP-71's four new
   constructors, including `StateChangingEpsilon` (the compile-breaking migration
   that keiki MP-16's plan 71 documents, with suggested rendering text to reuse).
   EP-99 does NOT implement a keiro-side silent-edge scan and does NOT extend
   keiki's `TransducerValidationWarning` — detection is keiki EP-71's (revised
   division, 2026-07-12); EP-99 instead force-enables the replay-contract checks
   (`checkStateChangingEpsilon`, `checkHeadRecoverability`) against caller-supplied
   options and adds the loudly named unchecked-constructor escape hatch. Genuinely
   keiro-only stream rules keep following the `snapshotWarnings` precedent at
   Validate.hs:159-169. The two plans touch the same module; EP-95 lands first, so
   EP-99 rebases on its arms.

3. Telemetry counter names in `keiro/src/Keiro/Telemetry.hs` (EP-98 and EP-99 both
   add counters). Convention: follow the existing `keiro.snapshot.write.failures`
   dotted style (Telemetry.hs:563). Final registry as authored: EP-98 owns
   `keiro.snapshot.decode.failures`, `keiro.snapshot.encode.failures` (the runtime
   uninit-guard degrade path), `keiro.snapshot.read.hits`, and
   `keiro.snapshot.read.misses`; EP-99 owns `keiro.snapshot.apply.divergence` plus
   the `keiro.replay.divergence` span attribute, and deliberately adds NO ambiguity
   counter (ambiguity is a typed `CommandAmbiguous` error from EP-95, not a metric).
   One plan must not rename the other's counters.

4. Delivery-path duality (EP-96 defines, EP-100 respects). keiro has two delivery
   paths: the shibuya-kiroku adapter (ack-coupled, correct today) and the sharded
   worker (EP-96 converts it to `subscriptionAckStream`). EP-100's dead-letter and
   retry-exhaustion work must function on BOTH paths. As authored, the artifacts to
   reconcile at implementation time are EP-96's `ShardAck`/`ShardDelivery` surface
   and `runShardedSubscriptionGroupAck` entry point versus EP-100's shared
   `decideForFailures` policy function — the two plans were authored concurrently
   against each other's skeletons and state the contract as expectations; whichever
   implements second wires `decideForFailures` into the `ShardAck` reply.

5. The keiki boundary (all plans). What keiki MP-16 already delivers and keiro must
   NOT re-implement: validator/replay head-recoverability agreement (keiki EP-71);
   the structured replay failure vocabulary and seedable fold (keiki EP-72 — keiro
   DELETES its hand-rolled folds rather than improving them); authoring-time
   emit/noEmit intent (keiki plan 68); wire-format goldens and the shape-hash
   stability fix (keiki EP-78 — keiro's snapshot lookups treat a changed hash as a
   benign miss; EP-98 notes the one-time full-replay cost at the keiki upgrade
   rather than fixing it); event-codec versioning (keiki EP-77 — irrelevant to
   keiro, which uses its own `Keiro.Codec`). What keiro owns because keiki cannot
   know the runtime model: *enforcement* of the ε-edge rejection (keiki EP-71
   detects state-changing epsilon with its default-on warning; keiro force-enables
   the check and fails `mkEventStream` — only keiro knows events are the sole
   persistence, so only keiro may refuse to offer an opt-out), operational
   enforcement of the uninitialized-slot precondition (keiki EP-78 deliberately
   chose documentation over a total encode), and everything in Phases 2–4.


## Progress

- [x] EP-95: keiro compiles against post-MP-16 keiki; Validate.hs renders the four new keiki warning constructors
- [x] EP-95: hydrate/hydrateFull folds replaced by keiki's seedable structured fold; hydration failures carry event index and typed reason
- [x] EP-95: command evaluation distinguishes ambiguous guards from business rejection in `CommandError` and `error.type`
- [x] EP-96: sharded worker acks after the handler returns; batch-tail crash/rebalance loses nothing
- [x] EP-96: rebalance-under-load and zombie-overlap tests exist and pass
- [x] EP-97: router event ids derived from target stream names; unstable-resolve redelivery test passes; dropped-target semantics decided and documented
- [x] EP-98: uninit-register encode caught at mkEventStream and degraded to the counted advisory path at write time
- [x] EP-98: snapshot read-side telemetry (decode failures at minimum); workflow snapshot writes swallowed-and-counted like the command path
- [x] EP-99: keiki's `StateChangingEpsilon` and `checkHeadRecoverability` force-enabled at stream validation (no caller opt-out; bypass only via the named unchecked constructor); the every-append replay-divergence check counts witnesses, never discards them
- [x] EP-99: no-op `CommandResult.globalPosition` normalized to `Nothing`
- [x] EP-100: rejected PM commands dead-letter instead of halt-looping; saga-state/dispatch divergence documented or closed
- [x] EP-100: retry exhaustion documented; kiroku dead-letter replay path exists
- [x] EP-101: rebuild resets projection dedup; writers fenced during rebuild; `Strong` usable with multiple active categories
- [x] EP-102: truncation contiguity guard; enrichment parity between append paths; messaging caveats documented


## Surprises & Discoveries

- The 2026-07 review verified several feared failure modes are impossible by
  construction: kiroku allocates batch global positions contiguously under the
  `$all` row lock (commit order equals position order, so `reconstructRecorded` is
  exact and subscription readers need no skew handling), and mid-chain snapshots
  cannot be persisted because the snapshot fold runs keiki's chunk-semantics
  `applyEvents` over the full command batch. Plans must not "fix" these.
- kiroku's checkpoint upsert already uses `GREATEST(last_seen, EXCLUDED.last_seen)`,
  so the Worker.hs docstring's zombie-regression warning is stale (doc fix in
  EP-96's scope, not a behavior change).
- EP-96 delivered the Integration Point 4 surface as `ShardDelivery`, `ShardAck`,
  `ShardEventHandler`, and `runShardedSubscriptionGroupAck`. EP-100 can implement
  its shard-path rejection policy by returning `ShardAckDeadLetter` or
  `ShardAckRetry`; no further shard-worker hook is required. Synchronous handler
  exceptions are already bounded by the configured kiroku retry policy, and
  exhaustion is observable in `kiroku.dead_letters`.
- The jitsurei example repos are outdated (user directive, 2026-07-12): no plan may
  use them as evidence or include migrating them in scope. (The in-repo `jitsurei`
  package still must compile; EP-95 and EP-102 record compile-verification-only
  decisions for it.)
- EP-101 reproduced both read-model defects before closing them: a literal run of
  the former rebuild procedure promoted an empty table because retained dedup keys
  skipped replay, and an otherwise caught-up category subscription timed out for
  5.199 seconds after unrelated traffic advanced the all-stream head. Atomic reset
  helpers and `CategoryHead` strong scope now make both invariants executable.
- Kiroku's monotonic checkpoint save cannot reset a subscription for replay. EP-101
  therefore performs the direct checkpoint reset only inside `startRebuild`'s
  transaction, under the same registry lock that excludes live projection writers.
- EP-102 integrated its truncation guard into EP-95's shared page-oriented replay
  feed, preserving earlier replay-failure precedence while rejecting a gap before
  decoding its suffix. Its red run confirmed that the previous full-hydration path
  could append from silently incomplete state.
- Kiroku 0.3's resource-aware transactional convenience wrapper exposes only an
  `AppendResult`, but Keiro's callback contract also needs reconstructed enriched
  `RecordedEvent`s. EP-102 therefore retained the low-level transaction shape and
  explicitly enriched before preparation; the parity regression proves both the
  stored rows and callback records carry the hook metadata.
- Plan authoring (2026-07-12) surfaced discoveries that reshaped the plans:
  - EP-97's verification sharpened the router defect model: kiroku's GLOBAL primary
    key on `event_id` means a pure order swap cannot double-dispatch after full
    completion — the misplaced id is rejected and the loose `DuplicateEvent` fold
    masks it. The real failures are silently DROPPED dispatches on set drift and
    double-dispatch-plus-drop in crash-window reorders; the plan's red tests target
    exactly those, and the fold tightening must land after the id fix.
  - EP-99 found the feared register-only blind spot does not exist: keiki exports
    `Update (..)` with all constructors, so the full silent-edge rule (empty output
    with a vertex change OR any syntactic register write) was implementable
    keiro-side. Superseded 2026-07-12: keiki MP-16's revision moved detection into
    keiki EP-71 (`StateChangingEpsilon`, default-on) to keep a single AST traversal
    next to the types it walks; EP-99 now force-enables and pins that check instead
    of implementing its own scan.
  - EP-98 found that keiki's write-path strictness means the validation-time
    force-encode of the INITIAL state covers the entire `emptyRegFile` hazard class
    for validated streams, and that `rotateGeneration`'s unconditional seed write
    is already documented as deliberate (kept).
  - EP-95 resolved the fail-vs-warn question for keiki EP-71's new warnings without
    new code: `mkEventStreamWith` already rejects ANY warning, so the
    replay-breaking warnings are automatically fail-fast at keiro's boundary. EP-99
    additionally force-enables the replay-contract flags so caller-supplied options
    cannot weaken them.
  - EP-100 found kiroku already emits `KirokuEventSubscriptionDeadLettered` through
    its store-level `eventHandler` (exhaustion surfacing is a bridge, not new
    plumbing), that `KirokuAdapterConfig` never exposes `retryPolicy` (documented
    upstream gap), and that a "dispatch dead-lettered" marker event on the PM's own
    stream is UNSOUND (a foreign event wedges the manager's own transducer replay)
    — not merely deferred.
  - EP-102's enrichment-parity fix is a keiro-internal breaking change: kiroku's
    resource constructor is unexported, so the transactional runners gain a
    constraint that propagates to `runCommandWithProjections`,
    `runProcessManagerOnce`, and `runRouterOnce`.
  - EP-101 confirmed kiroku exports no category-head query, so `Strong`'s per-model
    scope uses a keiro-side SQL query with the coupling assessed in its Decision
    Log; the checkpoint-advance-on-empty-fetch alternative is noted as the upstream
    kiroku fix.
- EP-97 implementation found the authored colon-delimited UUID-v5 name was itself
  collision-prone for colon-bearing fields and non-ASCII text. The delivered router
  derivation length-prefixes each UTF-8 field and has direct regression coverage. It
  also exported `confirmBenignDuplicate` from `Keiro.ProcessManager`; EP-100 must
  preserve this per-target confirmation when it converts rejected or failed dispatches
  into dead-letter outcomes.
- EP-95 implementation started after keiki MP-16 completed and release 0.2.0.0 was
  published to Hackage. Keiro now consumes the ordinary Hackage packages with PVP
  0.2 bounds rather than Git pins. Keiki EP-76's strengthened pure overlap proof
  recognizes the originally authored `PAnd ... PTop` ambiguity fixture, so EP-95 uses
  runtime-true `PAnd ... (PNot PBot)` guards outside the proof fragment to retain a
  validated runtime-ambiguity witness for the command taxonomy tests.
- The user-owned `cabal.project.local` overlaid kiroku 0.3.0.0 on the older pinned
  source revision and initially broke default dependency solving. During EP-95 the
  user confirmed pg-migrate and the latest Kiroku releases were on Hackage. Removing
  both projects' source pins and the local overlay now resolves
  `kiroku-store-0.3.0.0`, `kiroku-store-migrations-0.2.0.0`, and pg-migrate 1.0 from
  Hackage; default `cabal build all` and all 309 `keiro-test` examples pass.
- EP-95's optional repository-wide verification found the Jitsurei migration recipe
  still spoke the retired bare/Codd CLI. The recipe now uses native pg-migrate's
  explicit `up --database-url` form. Verification passed against a fresh task-scoped
  database; the existing legacy developer database was intentionally left untouched.
- EP-99 reused EP-95's head-unrecoverable stream as the runtime divergence witness:
  it has the same split-coverage defect the authored duplicate fixture was meant to
  model. The delivered span attribute records only event index and typed reason
  class, preserving EP-100's failure vocabulary without adding `Show` constraints
  or leaking command/event payloads. This does not alter any later plan dependency
  or integration point.
- EP-100 implementation corrected two authored assumptions against Kiroku's live
  API and worker semantics. `GlobalPosition` is opaque and forbids arithmetic, so
  replay resolves sources with one backward `$all` scan per batch; and an unsharded
  subscription retries the current event in place, so overtaking occurs only through
  independent append timing or sharded concurrency, not within its serial loop.
- EP-100's repository gate first exposed migration-ledger drift in the existing
  developer Jitsurei database: a constraint was present while its migration remained
  pending. Verification passed against a fresh task-scoped database, and the existing
  database was deliberately left untouched.


## Decision Log

- Decision: start EP-95 against Hackage `keiki-0.2.0.0` and
  `keiki-codec-json-0.2.0.0`, removing the old Git source overrides and constraining
  direct dependencies to the PVP-compatible 0.2 series.
  Rationale: keiki MP-16 is Complete and the user confirmed its 0.2.0.0 release is
  now on Hackage, satisfying EP-95's external hard dependency and explicitly asking
  keiro to consume the latest published release.
  Date: 2026-07-13

- Decision: replace the Kiroku and pg-migrate source pins with Hackage releases and
  remove `cabal.project.local` as part of EP-95's dependency migration.
  Rationale: every directly consumed package is now published, the user explicitly
  requested the cleanup, and the default build and full Keiro test suite demonstrate
  that the local source graph is no longer required.
  Date: 2026-07-13

- Decision: assume keiki MP-16 is implemented before this initiative; make EP-95 the
  Phase 1 foundation and let later plans consume MP-16's structured APIs instead of
  reconstructing diagnostics around bare `Maybe`s.
  Rationale: user directive 2026-07-12 ("we can make the assumption that keiki MP
  will be implemented first"); it deletes ~100 lines of duplicated fold code and
  gives every downstream plan a typed vocabulary for free.
  Date: 2026-07-12

- Decision: state-changing silent edges are DETECTED by keiki (EP-71's default-on
  `StateChangingEpsilon` warning) and ENFORCED by keiro: `mkEventStream` fails on
  the warning; keiro force-enables `checkStateChangingEpsilon` and
  `checkHeadRecoverability` regardless of caller-supplied `ValidationOptions`
  (caller options may only strengthen validation at the durable boundary); and the
  only bypass is a separately named unchecked constructor, never an options field.
  This applies to aggregates and process managers alike.
  Rationale: agreed division with keiki MP-16 (2026-07-12, superseding this plan's
  original keiro-side-scan decision). The check is a structural traversal of keiki's
  own edge/update AST, and a downstream copy would drift when keiki EP-74/EP-75
  reshape that AST. ε-edges stay legal in keiki's pure model via keiki's opt-out,
  which keiro's boundary must not expose: under the zero-silent-divergence
  principle, a config knob that can reach durable streams is itself a bug vector.
  Keiro's runtime divergence witnesses (EP-99 M2) are retained as defense in depth
  behind the static checks. The non-contract checks (`checkInversionAmbiguity`,
  `checkGuardImpliesInputRead`) stay caller-narrowable — they have a documented
  legitimate-override story, and the divergence witness is the net for a wrong
  override.
  Date: 2026-07-12 (supersedes the earlier keiro-side-rule entry of the same date)

- Decision: keiro enforces the uninitialized-register-slot precondition itself
  (validation-time force-encode plus a runtime force inside the advisory swallow),
  even though keiki EP-78 documents the same precondition.
  Rationale: keiki EP-78 deliberately chose documentation + a sharpened error over a
  total encode; keiro is where the exception escapes a post-commit advisory path,
  tears a pooled connection, and recurs per snapshot boundary — an operational
  hazard only the runtime can neutralize. Enforcement is not duplication of a
  documentation decision.
  Date: 2026-07-12

- Decision: fix the sharded worker by consuming kiroku's existing
  `subscriptionAckStream` rather than adding a kiroku-side child plan.
  Rationale: the ack-coupled bridge already exists and is proven by the
  shibuya-kiroku adapter path; the defect is keiro's choice of the non-acking
  bridge.
  Date: 2026-07-12

- Decision: no plan migrates or cites the jitsurei example repos.
  Rationale: user directive 2026-07-12 — they are very outdated.
  Date: 2026-07-12


## Outcomes & Retrospective

EP-95 completed Phase 1's keiki alignment. The durable boundary now rejects all four
new replay-breaking warnings, hydration reports exact versions and typed structured
reasons through a single seeded fold, and command ambiguity is distinct from business
rejection through `CommandAmbiguous` and `command_ambiguous` telemetry. This unblocks
EP-99 directly and gives EP-100/EP-102 the planned failure vocabulary.

The dependency graph also became simpler than authored: Keiki 0.2, Kiroku 0.3/0.2,
and pg-migrate 1.0 all resolve from Hackage, so their Git pins and the local Cabal
overlay are gone. Final evidence is `cabal build all`, 309 Keiro examples, the PGMQ
and Jitsurei suites, formatting, and a fresh-database repository-wide verification
including migration and site checks.

EP-99 completed Phase 3's command-path hardening. Durable stream validation cannot
disable Keiki's two replay-contract checks; every append path detects and observes a
poisoned just-committed batch without misreporting the commit as failed; and no-op
command results no longer expose Kiroku's per-stream-read position sentinel. The
operator-facing changelog and telemetry audit now describe the compatibility break,
the default-on verification option, and the divergence counter/attribute contract.
Final evidence is formatting, whole-workspace Haddock and build success, and 316
Keiro examples with zero failures.

EP-100 completed Phase 3's coordination failure-path hardening. Process-manager and
router workers now share a typed rejection policy whose safe default still halts,
while opt-in dead-letter and skip outcomes let modeled business rejections advance
without disguising systemic failures. Durable dispatch records, terminal-subscription
telemetry, idempotent Kiroku dead-letter replay, and explicit cross-stream ordering
and transaction contracts provide the operator path the review found missing. Final
evidence is a fresh-database `just verify`: 325 Keiro examples, all package and
migration suites, the whole workspace build, and the generated-site link check passed.

EP-101 completed the read-model half of Phase 4. Registration is explicit and fails
closed, rebuild reset is atomic across status, data, dedup keys, and checkpoint,
normal async writers are fenced by the registry row lock, guarded promotion rejects
an empty replay, and strong reads can target a category head instead of unrelated
all-stream traffic. The unsafe prose procedure is retired in favor of the helper
sequence. Final evidence is `just haskell-build`, successful Keiro Haddock generation,
and 331 Keiro examples with zero failures.

EP-102 completed the persistence-polish half of Phase 4 and the initiative. Command
hydration now fails closed on stream versions hidden without a covering snapshot;
plain and transactional command paths apply the same Kiroku enrichment hook; and the
truncation, inbox retention, outbox ordering, and transactional `$all` lock contracts
are documented at their operational entry points. Final evidence is `nix fmt`,
`cabal build all`, and 335 Keiro examples with zero failures. All eight child plans
are complete.

## Revision Notes

- 2026-07-13: Completed EP-102 and MasterPlan 14. Added truncation-gap guards,
  resource-aware transactional enrichment parity, operator-facing messaging and
  persistence caveats, and passed the workspace build plus all 335 Keiro examples.

- 2026-07-13: Completed EP-101. Added explicit read-model registration, atomic
  rebuild reset and guarded promotion, database-backed async writer fencing,
  category-scoped strong reads, red/green and concurrency coverage, and the
  helper-enforced operator workflow. Build, Haddock, and all 331 Keiro examples
  passed.

- 2026-07-13: Completed EP-100. Added durable rejected-dispatch records and shared
  process-manager/router policies, surfaced bounded Kiroku retry exhaustion, added
  idempotent source-event replay, documented ordering and transaction boundaries,
  and passed the full repository gate against a fresh task-scoped database.

- 2026-07-13: Completed EP-99. Force-enabled durable replay validation, added
  default-on divergence witnesses to both append paths, normalized no-op global
  positions, documented the telemetry and compatibility contracts, and passed
  formatting, whole-workspace Haddock/build, and all 316 Keiro examples.

- 2026-07-13: Completed EP-95. Marked its registry row and three outcomes complete;
  adopted structured replay/step diagnostics and reason-specific telemetry, recorded
  the 309-example/full-workspace verification, and unblocked EP-99's hard dependency.

- 2026-07-13: Removed the now-obsolete Kiroku and pg-migrate Git pins plus the local
  Cabal overlay, constrained Kiroku to its published 0.3/0.2 package lines, and proved
  the ordinary Hackage workflow with `cabal build all` and all 308 Keiro tests.

- 2026-07-13: Unblocked EP-95 after keiki MP-16 completed and keiki 0.2.0.0 reached
  Hackage. Marked EP-95 In Progress, replaced its authored Git-pin step with Hackage
  0.2 bounds, and recorded the ambiguity-fixture adjustment required by keiki EP-76's
  stronger pure overlap proof.

- 2026-07-13: Completed EP-97. Router ids are keyed by target stream and same-stream
  occurrence with a legacy positional transition probe; all duplicate-rejection folds
  confirm the attempted id in the intended stream; and Haddocks, the router guide, and
  changelog state the resolver-drift union contract. Formatting and build passed, and
  the full `keiro-test` suite reported 295 examples with zero failures.

- 2026-07-13: Completed EP-96. The sharded worker now acknowledges only after the
  handler returns, retries synchronous failures within a configurable bound, and
  exposes the per-event acknowledgement surface EP-100 consumes. Added passing
  batch-tail cancellation, forced-rebalance, zombie-overlap, and poison-event
  coverage; marked both EP-96 progress outcomes complete.

- 2026-07-12: Aligned with keiki MP-16's revised division of labor for
  state-changing silent edges: detection moved to keiki EP-71 (a fourth warning
  constructor, `StateChangingEpsilon`, default-on), so EP-95 renders four arms (not
  three) and EP-99 no longer implements a keiro-side scan — it force-enables the
  replay-contract checks (`checkStateChangingEpsilon`, `checkHeadRecoverability`)
  against caller-supplied options, adds the loudly named unchecked-constructor
  escape hatch, and keeps its runtime divergence witnesses as defense in depth.
  Superseded the ε-edge Decision Log entry and the EP-99 `Update (..)` discovery
  note accordingly.

- 2026-07-12: Initial creation — eight child plans (95–102) across four phases,
  grounded in the 2026-07 keiki-path review of keiro, with the standing assumptions
  that keiki MasterPlan 16 lands first and that nothing here duplicates it. After
  all children were authored, updated Integration Point 3 with the final telemetry
  counter registry (including EP-98's `keiro.snapshot.encode.failures` and EP-99's
  no-ambiguity-counter decision), named the concrete EP-96/EP-100 artifacts to
  reconcile in Integration Point 4, and recorded seven authoring-time discoveries
  in Surprises & Discoveries — most notably EP-97's sharpened router defect model
  (silent drops, not double-dispatch, are the primary failure) and EP-99's finding
  that keiki already exports enough to implement the full silent-edge rule.

- 2026-07-13: Completed EP-98. Snapshot-enabled streams now reject unencodable
  initial registers; command snapshot encoding and all workflow snapshot writes
  degrade through counted advisory paths; aggregate and workflow reads expose
  hit, miss, and decode-failure telemetry; and operator docs state the
  codec-mismatch rollback clobber plus Keiki EP-78 replay cost. Validation passed
  the whole workspace build, Haddock render, and 300-example PostgreSQL suite.
